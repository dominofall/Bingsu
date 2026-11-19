// 놋그릇 울타리(fence) — 가져온 RPG Maker 게임의 Ruby 스크립트가 빙수 앱 폴더 전체에 닿지 못하게 한다 (빌드 46).
//
// 엔진(mkxp-z)과 Ruby·SDL·PhysFS 는 이 프레임워크 안에 정적으로 링크된다. 그 안에서 부르는 libc 파일·네트워크·프로세스 함수
// (open, stat, opendir, rename, socket ...)를 이 파일이 같은 이름으로 정의해 가로챈다. 링커는 프레임워크 안의 정의를 먼저 쓰고,
// 이 이름들은 내보내지 않으므로(brassbowl.exports 는 mkxp_* 뿐) 빙수 앱 본체와 시스템 프레임워크의 호출은 그대로다.
//
// 규칙 (켜진 동안):
// - 쓰기·지우기·이름 바꾸기·만들기: 쓰기 허용 폴더(그 게임 폴더, 저장 폴더, 임시 폴더) 안에서만
// - 읽기·목록·stat: 보호 구역(앱 데이터 컨테이너 전체와 같은 사용자의 다른 컨테이너) 안이면 허용 폴더(위 + 앱 번들)만. 그 밖(시스템 파일)은 허용
// - 링크·심볼릭 링크 만들기, 프로세스 실행, syscall: 항상 거부
// - 네트워크(소켓, 이름 풀기): "온라인 접속 허용" 이 꺼진 게임은 거부
// - 이미 열린 파일 번호를 IO.new(fd) 로 집는 길: fcntl(F_GETFL)·fstat 에서 그 번호의 경로를 보고 막는다
// 거부하면 errno = EACCES (fd 는 EBADF) 로 실패를 돌려준다. 게임에는 "파일이 없는" 것과 비슷하게 보인다.
//
// 한계: 프레임워크 밖(Foundation 등)을 거쳐 파일에 닿는 엔진 코드는 대상이 아니다(게임 스크립트가 고를 수 없는 길).
// 허용 폴더 안의 심볼릭 링크는 따라가지 않고 판단한다(가져오기가 심볼릭 링크를 거부하고, 게임은 새로 만들 수 없다).

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netdb.h>
#include <os/log.h>
#include <spawn.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <dirent.h>
#include <unistd.h>

#define FENCE_MAX_ROOTS 24
#define FENCE_BUF (PATH_MAX * 2)

typedef struct { char path[PATH_MAX]; size_t len; } Root;
typedef struct { Root items[FENCE_MAX_ROOTS]; int count; } RootList;

static RootList g_write, g_read, g_code, g_protect;
static atomic_int g_on = 0;
static atomic_int g_net = 1;
static atomic_int g_denials = 0;

// MARK: 진짜 함수 (libSystem). 이 파일 안에서 open 등을 부르면 자기 자신이므로 반드시 이 포인터로

static void *real(const char *name) { return dlsym(RTLD_DEFAULT, name); }
#define REAL(T, name) ((T)real(name))

static char *real_realpath(const char *p, char *out) {
    static char *(*fn)(const char *, char *);
    if (!fn) fn = REAL(char *(*)(const char *, char *), "realpath$DARWIN_EXTSN");
    if (!fn) fn = REAL(char *(*)(const char *, char *), "realpath");
    return fn ? fn(p, out) : NULL;
}
static int real_fcntl_getpath(int fd, char *out) {
    static int (*fn)(int, int, ...);
    if (!fn) fn = REAL(int (*)(int, int, ...), "fcntl");
    return fn ? fn(fd, F_GETPATH, out) : -1;
}

// MARK: 경로

/// `.`·`..`·겹친 `/` 를 글자로만 정리한다 (파일 시스템을 보지 않음)
static void normalize(char *p) {
    char out[FENCE_BUF];
    size_t o = 0;
    const char *s = p;
    while (*s) {
        while (*s == '/') s++;
        if (!*s) break;
        const char *e = s;
        while (*e && *e != '/') e++;
        size_t n = (size_t)(e - s);
        if (n == 1 && s[0] == '.') {
        } else if (n == 2 && s[0] == '.' && s[1] == '.') {
            while (o > 0 && out[o - 1] != '/') o--;
            if (o > 0) o--;
        } else if (o + 1 + n < sizeof out) {
            out[o++] = '/';
            memcpy(out + o, s, n);
            o += n;
        }
        s = e;
    }
    if (o == 0) out[o++] = '/';
    out[o] = 0;
    memcpy(p, out, o + 1);
}

/// dirfd 기준 절대 경로. 실패하면 0
static int absolute(int dirfd, const char *path, char *out) {
    if (!path) return 0;
    if (path[0] == '/') {
        if (strlen(path) >= FENCE_BUF) return 0;
        strcpy(out, path);
    } else {
        char base[PATH_MAX];
        if (dirfd == AT_FDCWD) {
            if (!getcwd(base, sizeof base)) return 0;
        } else if (real_fcntl_getpath(dirfd, base) == -1) {
            return 0;
        }
        if (strlen(base) + 1 + strlen(path) >= FENCE_BUF) return 0;
        snprintf(out, FENCE_BUF, "%s/%s", base, path);
    }
    normalize(out);
    return 1;
}

/// 심볼릭 링크를 푼 경로. 아직 없는 파일이면 있는 조상까지 풀고 나머지를 붙인다
static void canonical(const char *abs, char *out) {
    char head[FENCE_BUF];
    strcpy(head, abs);
    char tail[FENCE_BUF] = "";
    for (;;) {
        char resolved[PATH_MAX];
        if (real_realpath(head, resolved)) {
            snprintf(out, FENCE_BUF, "%s%s", resolved, tail);
            normalize(out);
            return;
        }
        char *slash = strrchr(head, '/');
        if (!slash || slash == head) { strcpy(out, abs); return; }
        char t[FENCE_BUF];
        snprintf(t, sizeof t, "%s%s", slash, tail);
        strcpy(tail, t);
        *slash = 0;
    }
}

static int under(const RootList *list, const char *p) {
    for (int i = 0; i < list->count; i++) {
        const Root *r = &list->items[i];
        if (strncmp(p, r->path, r->len) == 0 && (p[r->len] == 0 || p[r->len] == '/' || r->len == 1)) return 1;
    }
    return 0;
}

static void add(RootList *list, const char *p) {
    if (!p || !*p) return;
    char abs[FENCE_BUF];
    if (!absolute(AT_FDCWD, p, abs)) return;
    char forms[2][FENCE_BUF];
    strcpy(forms[0], abs);
    canonical(abs, forms[1]);
    for (int f = 0; f < 2; f++) {
        if (list->count >= FENCE_MAX_ROOTS || strlen(forms[f]) >= PATH_MAX) return;
        if (f == 1 && strcmp(forms[0], forms[1]) == 0) return;
        Root *r = &list->items[list->count++];
        strcpy(r->path, forms[f]);
        r->len = strlen(r->path);
    }
}

/// META: stat·access 처럼 있는지·속성만 보는 것. 허용 폴더의 조상 폴더 자체는 볼 수 있다(PhysFS 가 시작할 때 집 폴더를 stat 한다).
/// 목록(opendir)과 내용(open)은 READ 라 조상이어도 막힌다
typedef enum { READ, WRITE, CODE, META } Mode;

/// p 가 어느 허용 폴더의 조상 폴더 자체인가
static int ancestor_of_root(const char *p) {
    const RootList *lists[3] = { &g_read, &g_write, &g_code };
    size_t n = strlen(p);
    for (int l = 0; l < 3; l++)
        for (int i = 0; i < lists[l]->count; i++) {
            const Root *r = &lists[l]->items[i];
            if (n == 1 && p[0] == '/') return 1;
            if (r->len > n && strncmp(r->path, p, n) == 0 && r->path[n] == '/') return 1;
        }
    return 0;
}

static void note(const char *op, const char *path) {
    int n = atomic_fetch_add(&g_denials, 1);
    if (n < 50) os_log_error(OS_LOG_DEFAULT, "[BrassBowl] fence deny %{public}s %{public}s", op, path ? path : "-");
    else if (n == 50) os_log_error(OS_LOG_DEFAULT, "[BrassBowl] fence deny ... (more not logged)");
}

static int decide(Mode m, const char *p) {
    switch (m) {
    case WRITE: return under(&g_write, p);
    case READ: return under(&g_read, p) || under(&g_write, p) || under(&g_code, p) || !under(&g_protect, p);
    case CODE: return under(&g_code, p) || !under(&g_protect, p);
    case META: return under(&g_read, p) || under(&g_write, p) || under(&g_code, p) || ancestor_of_root(p) || !under(&g_protect, p);
    }
    return 0;
}

// MARK: 효과음 신호 (빌드 51, docs/rumble/PLAN-defaults.md 2단계)
// 빙수 preload(BrassBowlEngine.sfxScript)는 진동표에 있는 효과음이 날 때 File.exist?("/.bingsu-sfx/<이름>") 을 부른다.
// 루비 1.8·1.9·3.1 모두 stat 계열로 여기를 지나므로, 이 경로는 디스크에 닿지 않고 빙수가 등록한 함수로 이름만 넘긴 뒤 "없음"으로 끝낸다.
// 울타리를 켜고 끄는 것과 무관하게 동작한다. 게임 스크립트가 직접 불러도 빙수 진동표에 맞는 이름만 울리고, 빙수 쪽에서 빈도를 자른다.

#define SFX_PREFIX "/.bingsu-sfx/"
static void (*_Atomic g_sfx)(const char *) = NULL;

void mkxp_sfxSetHandler(void (*fn)(const char *)) { atomic_store(&g_sfx, fn); }

/// 효과음 신호 경로면 1 (처리 끝). 아니면 0
static int sfx_signal(const char *path) {
    if (!path || strncmp(path, SFX_PREFIX, sizeof(SFX_PREFIX) - 1) != 0) return 0;
    const char *name = path + sizeof(SFX_PREFIX) - 1;
    void (*fn)(const char *) = atomic_load(&g_sfx);
    if (fn && *name && strnlen(name, 256) < 256) fn(name);
    return 1;
}

/// 허용이면 1. 거부면 errno 를 채우고 0
static int check(const char *op, int dirfd, const char *path, Mode m) {
    if (sfx_signal(path)) { errno = ENOENT; return 0; }
    if (!atomic_load(&g_on) || !path) return 1;
    char abs[FENCE_BUF];
    if (!absolute(dirfd, path, abs)) { note(op, path); errno = EACCES; return 0; }
    // 허용 폴더 안이면 글자만 보고 통과 (자주 불리는 길을 가볍게). 폴더는 적은 그대로와 심볼릭 링크를 푼 꼴 둘 다 들어 있다
    if (m == WRITE ? under(&g_write, abs) : (m != CODE && (under(&g_read, abs) || under(&g_write, abs) || under(&g_code, abs)))) return 1;
    if (m == META && ancestor_of_root(abs)) return 1;
    // 그 밖은 링크를 풀어서 본다 (/var → /private/var, 상위 폴더로 빠지는 길)
    char canon[FENCE_BUF];
    canonical(abs, canon);
    if (decide(m, canon) && (m == WRITE || under(&g_code, abs) || !under(&g_protect, abs))) return 1;
    note(op, abs);
    errno = EACCES;
    return 0;
}

/// 이미 열린 번호가 보호 구역의 파일이면 0 (IO.new(fd)·IO.for_fd 막기)
static int check_fd(const char *op, int fd) {
    if (!atomic_load(&g_on) || fd < 0) return 1;
    char p[PATH_MAX];
    if (real_fcntl_getpath(fd, p) == -1) return 1;   // 파이프·소켓 등 경로 없는 것
    char canon[FENCE_BUF];
    canonical(p, canon);
    if (decide(READ, canon)) return 1;
    note(op, canon);
    errno = EBADF;
    return 0;
}

static int deny_always(const char *op, const char *what) {
    if (!atomic_load(&g_on)) return 1;
    note(op, what);
    errno = EPERM;
    return 0;
}

static int net_ok(const char *op) {
    if (!atomic_load(&g_on) || atomic_load(&g_net)) return 1;
    note(op, "network off");
    errno = EACCES;
    return 0;
}

static int writes(int flags) { return (flags & O_ACCMODE) != O_RDONLY || (flags & (O_CREAT | O_TRUNC | O_APPEND)); }
static int mode_writes(const char *mode) { return mode && (strchr(mode, 'w') || strchr(mode, 'a') || strchr(mode, '+')); }

// MARK: 빙수가 부르는 설정 (brassbowl.exports 의 mkxp_* 로 내보냄)

void mkxp_fenceReset(void) {
    atomic_store(&g_on, 0);
    atomic_store(&g_net, 1);
    atomic_store(&g_denials, 0);
    g_write.count = g_read.count = g_code.count = g_protect.count = 0;
}
/// kind: 0 읽기 허용, 1 쓰기 허용(읽기 포함), 2 코드(앱 번들, dlopen 허용), 3 보호 구역
void mkxp_fenceAdd(const char *path, int kind) {
    switch (kind) {
    case 0: add(&g_read, path); break;
    case 1: add(&g_write, path); break;
    case 2: add(&g_code, path); break;
    case 3: add(&g_protect, path); break;
    }
}
void mkxp_fenceSetNetwork(int on) { atomic_store(&g_net, on ? 1 : 0); }
void mkxp_fenceEnable(int on) {
    atomic_store(&g_on, on ? 1 : 0);
    os_log(OS_LOG_DEFAULT, "[BrassBowl] fence %{public}s write=%d read=%d code=%d protect=%d net=%d", on ? "on" : "off",
           g_write.count, g_read.count, g_code.count, g_protect.count, atomic_load(&g_net));
}
int mkxp_fenceDenials(void) { return atomic_load(&g_denials); }
/// 시험용: 이 경로를 읽기(0)·쓰기(1)로 열 수 있는지 (실제로 열지 않음)
int mkxp_fenceAllows(const char *path, int write) {
    int saved = errno;
    int ok = check("probe", AT_FDCWD, path, write ? WRITE : READ);
    errno = saved;
    return ok;
}

// MARK: 가로채는 함수 — 이름은 프레임워크가 가져오는 기호와 똑같이 (__asm__)

int fence_open(const char *path, int flags, ...) __asm__("_open");
int fence_open(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap); }
    if (!check("open", AT_FDCWD, path, writes(flags) ? WRITE : READ)) return -1;
    static int (*fn)(const char *, int, ...);
    if (!fn) fn = REAL(int (*)(const char *, int, ...), "open");
    return fn(path, flags, mode);
}

int fence_openat(int fd, const char *path, int flags, ...) __asm__("_openat");
int fence_openat(int fd, const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap); }
    if (!check("openat", fd, path, writes(flags) ? WRITE : READ)) return -1;
    static int (*fn)(int, const char *, int, ...);
    if (!fn) fn = REAL(int (*)(int, const char *, int, ...), "openat");
    return fn(fd, path, flags, mode);
}

FILE *fence_fopen(const char *path, const char *mode) __asm__("_fopen");
FILE *fence_fopen(const char *path, const char *mode) {
    if (!check("fopen", AT_FDCWD, path, mode_writes(mode) ? WRITE : READ)) return NULL;
    static FILE *(*fn)(const char *, const char *);
    if (!fn) fn = REAL(FILE *(*)(const char *, const char *), "fopen");
    return fn(path, mode);
}

FILE *fence_fopen_ext(const char *path, const char *mode) __asm__("_fopen$DARWIN_EXTSN");
FILE *fence_fopen_ext(const char *path, const char *mode) {
    if (!check("fopen", AT_FDCWD, path, mode_writes(mode) ? WRITE : READ)) return NULL;
    static FILE *(*fn)(const char *, const char *);
    if (!fn) fn = REAL(FILE *(*)(const char *, const char *), "fopen$DARWIN_EXTSN");
    if (!fn) fn = REAL(FILE *(*)(const char *, const char *), "fopen");
    return fn(path, mode);
}

FILE *fence_freopen(const char *path, const char *mode, FILE *f) __asm__("_freopen");
FILE *fence_freopen(const char *path, const char *mode, FILE *f) {
    if (path && !check("freopen", AT_FDCWD, path, mode_writes(mode) ? WRITE : READ)) return NULL;
    static FILE *(*fn)(const char *, const char *, FILE *);
    if (!fn) fn = REAL(FILE *(*)(const char *, const char *, FILE *), "freopen");
    return fn(path, mode, f);
}

DIR *fence_opendir(const char *path) __asm__("_opendir");
DIR *fence_opendir(const char *path) {
    if (!check("opendir", AT_FDCWD, path, READ)) return NULL;
    static DIR *(*fn)(const char *);
    if (!fn) fn = REAL(DIR *(*)(const char *), "opendir");
    return fn(path);
}

#define PATH1(ret, name, mode, fail, params, args, types)                      \
    ret fence_##name params __asm__("_" #name);                                \
    ret fence_##name params {                                                  \
        if (!check(#name, AT_FDCWD, path, mode)) return fail;                  \
        static ret(*fn) types;                                                 \
        if (!fn) fn = REAL(ret(*) types, #name);                               \
        return fn args;                                                        \
    }

PATH1(int, stat, META, -1, (const char *path, struct stat *b), (path, b), (const char *, struct stat *))
PATH1(int, lstat, META, -1, (const char *path, struct stat *b), (path, b), (const char *, struct stat *))
PATH1(int, access, META, -1, (const char *path, int m), (path, m), (const char *, int))
PATH1(int, chdir, READ, -1, (const char *path), (path), (const char *))
PATH1(ssize_t, readlink, META, -1, (const char *path, char *buf, size_t n), (path, buf, n), (const char *, char *, size_t))
PATH1(int, getattrlist, META, -1, (const char *path, void *a, void *buf, size_t n, unsigned int o), (path, a, buf, n, o),
      (const char *, void *, void *, size_t, unsigned int))
PATH1(int, chmod, WRITE, -1, (const char *path, mode_t m), (path, m), (const char *, mode_t))
PATH1(int, chown, WRITE, -1, (const char *path, uid_t u, gid_t g), (path, u, g), (const char *, uid_t, gid_t))
PATH1(int, mkdir, WRITE, -1, (const char *path, mode_t m), (path, m), (const char *, mode_t))
PATH1(int, mkfifo, WRITE, -1, (const char *path, mode_t m), (path, m), (const char *, mode_t))
PATH1(int, rmdir, WRITE, -1, (const char *path), (path), (const char *))
PATH1(int, unlink, WRITE, -1, (const char *path), (path), (const char *))
PATH1(int, remove, WRITE, -1, (const char *path), (path), (const char *))
PATH1(int, truncate, WRITE, -1, (const char *path, off_t n), (path, n), (const char *, off_t))
PATH1(int, lchmod, WRITE, -1, (const char *path, mode_t m), (path, m), (const char *, mode_t))
PATH1(int, lchown, WRITE, -1, (const char *path, uid_t u, gid_t g), (path, u, g), (const char *, uid_t, gid_t))
PATH1(int, lutimes, WRITE, -1, (const char *path, const struct timeval *t), (path, t), (const char *, const struct timeval *))
PATH1(int, utimes, WRITE, -1, (const char *path, const struct timeval *t), (path, t), (const char *, const struct timeval *))

int fence_fstatat(int fd, const char *path, struct stat *b, int flag) __asm__("_fstatat");
int fence_fstatat(int fd, const char *path, struct stat *b, int flag) {
    if (!check("fstatat", fd, path, META)) return -1;
    static int (*fn)(int, const char *, struct stat *, int);
    if (!fn) fn = REAL(int (*)(int, const char *, struct stat *, int), "fstatat");
    return fn(fd, path, b, flag);
}

int fence_utimensat(int fd, const char *path, const struct timespec t[2], int flag) __asm__("_utimensat");
int fence_utimensat(int fd, const char *path, const struct timespec t[2], int flag) {
    if (!check("utimensat", fd, path, WRITE)) return -1;
    static int (*fn)(int, const char *, const struct timespec[2], int);
    if (!fn) fn = REAL(int (*)(int, const char *, const struct timespec[2], int), "utimensat");
    return fn(fd, path, t, flag);
}

int fence_chroot(const char *path) __asm__("_chroot");
int fence_chroot(const char *path) {
    if (!deny_always("chroot", path)) return -1;
    static int (*fn)(const char *);
    if (!fn) fn = REAL(int (*)(const char *), "chroot");
    return fn(path);
}

int fence_mkstemps(char *path, int suffix) __asm__("_mkstemps");
int fence_mkstemps(char *path, int suffix) {
    if (!check("mkstemps", AT_FDCWD, path, WRITE)) return -1;
    static int (*fn)(char *, int);
    if (!fn) fn = REAL(int (*)(char *, int), "mkstemps");
    return fn(path, suffix);
}

int fence_rename(const char *from, const char *to) __asm__("_rename");
int fence_rename(const char *from, const char *to) {
    if (!check("rename", AT_FDCWD, from, WRITE) || !check("rename", AT_FDCWD, to, WRITE)) return -1;
    static int (*fn)(const char *, const char *);
    if (!fn) fn = REAL(int (*)(const char *, const char *), "rename");
    return fn(from, to);
}

char *fence_realpath(const char *path, char *out) __asm__("_realpath$DARWIN_EXTSN");
char *fence_realpath(const char *path, char *out) {
    if (!check("realpath", AT_FDCWD, path, META)) return NULL;
    return real_realpath(path, out);
}

// 링크는 보호 구역 파일을 허용 폴더 안으로 끌어올 수 있어 항상 막는다 (게임 실행에 필요 없음)
int fence_link(const char *a, const char *b) __asm__("_link");
int fence_link(const char *a, const char *b) {
    if (!deny_always("link", b)) return -1;
    static int (*fn)(const char *, const char *);
    if (!fn) fn = REAL(int (*)(const char *, const char *), "link");
    return fn(a, b);
}
int fence_symlink(const char *a, const char *b) __asm__("_symlink");
int fence_symlink(const char *a, const char *b) {
    if (!deny_always("symlink", b)) return -1;
    static int (*fn)(const char *, const char *);
    if (!fn) fn = REAL(int (*)(const char *, const char *), "symlink");
    return fn(a, b);
}

// MARK: 이미 열린 번호

int fence_fstat(int fd, struct stat *b) __asm__("_fstat");
int fence_fstat(int fd, struct stat *b) {
    if (!check_fd("fstat", fd)) return -1;
    static int (*fn)(int, struct stat *);
    if (!fn) fn = REAL(int (*)(int, struct stat *), "fstat");
    return fn(fd, b);
}

int fence_fcntl(int fd, int cmd, ...) __asm__("_fcntl");
int fence_fcntl(int fd, int cmd, ...) {
    va_list ap;
    va_start(ap, cmd);
    void *arg = va_arg(ap, void *);
    va_end(ap);
    if (cmd == F_GETFL && !check_fd("fcntl", fd)) return -1;
    static int (*fn)(int, int, ...);
    if (!fn) fn = REAL(int (*)(int, int, ...), "fcntl");
    return fn(fd, cmd, arg);
}

// MARK: 코드 불러오기·프로세스

void *fence_dlopen(const char *path, int mode) __asm__("_dlopen");
void *fence_dlopen(const char *path, int mode) {
    if (path && strchr(path, '/') && !check("dlopen", AT_FDCWD, path, CODE)) return NULL;
    static void *(*fn)(const char *, int);
    if (!fn) fn = REAL(void *(*)(const char *, int), "dlopen");
    return fn(path, mode);
}

int fence_execve(const char *p, char *const a[], char *const e[]) __asm__("_execve");
int fence_execve(const char *p, char *const a[], char *const e[]) {
    if (!deny_always("execve", p)) return -1;
    static int (*fn)(const char *, char *const[], char *const[]);
    if (!fn) fn = REAL(int (*)(const char *, char *const[], char *const[]), "execve");
    return fn(p, a, e);
}
pid_t fence_fork(void) __asm__("_fork");
pid_t fence_fork(void) {
    if (!deny_always("fork", NULL)) return -1;
    static pid_t (*fn)(void);
    if (!fn) fn = REAL(pid_t (*)(void), "fork");
    return fn();
}
int fence_posix_spawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *fa, const posix_spawnattr_t *at,
                       char *const a[], char *const e[]) __asm__("_posix_spawnp");
int fence_posix_spawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *fa, const posix_spawnattr_t *at,
                       char *const a[], char *const e[]) {
    if (!deny_always("posix_spawnp", file)) return EPERM;
    static int (*fn)(pid_t *, const char *, const posix_spawn_file_actions_t *, const posix_spawnattr_t *, char *const[], char *const[]);
    if (!fn) fn = REAL(int (*)(pid_t *, const char *, const posix_spawn_file_actions_t *, const posix_spawnattr_t *, char *const[], char *const[]), "posix_spawnp");
    return fn(pid, file, fa, at, a, e);
}
FILE *fence_popen(const char *cmd, const char *mode) __asm__("_popen$DARWIN_EXTSN");
FILE *fence_popen(const char *cmd, const char *mode) {
    if (!deny_always("popen", cmd)) return NULL;
    static FILE *(*fn)(const char *, const char *);
    if (!fn) fn = REAL(FILE *(*)(const char *, const char *), "popen$DARWIN_EXTSN");
    return fn(cmd, mode);
}
// Ruby Kernel#syscall. 번호만으로 무엇이든 부를 수 있어 켜진 동안은 항상 막는다
int fence_syscall(int n, ...) __asm__("_syscall");
int fence_syscall(int n, ...) {
    (void)n;
    if (!atomic_load(&g_on)) { errno = ENOSYS; return -1; }
    note("syscall", NULL);
    errno = EPERM;
    return -1;
}

// Ruby 1.9 는 Kernel#syscall 에 syscall 대신 __syscall 을 쓴다
long long fence___syscall(long long n, ...) __asm__("___syscall");
long long fence___syscall(long long n, ...) {
    (void)n;
    if (atomic_load(&g_on)) note("__syscall", NULL);
    errno = atomic_load(&g_on) ? EPERM : ENOSYS;
    return -1;
}

// MARK: 네트워크 ("온라인 접속 허용" 이 꺼진 게임)

int fence_socket(int domain, int type, int proto) __asm__("_socket");
int fence_socket(int domain, int type, int proto) {
    if (!net_ok("socket")) return -1;
    static int (*fn)(int, int, int);
    if (!fn) fn = REAL(int (*)(int, int, int), "socket");
    return fn(domain, type, proto);
}
int fence_getaddrinfo(const char *h, const char *s, const struct addrinfo *hints, struct addrinfo **res) __asm__("_getaddrinfo");
int fence_getaddrinfo(const char *h, const char *s, const struct addrinfo *hints, struct addrinfo **res) {
    if (!net_ok("getaddrinfo")) return EAI_FAIL;
    static int (*fn)(const char *, const char *, const struct addrinfo *, struct addrinfo **);
    if (!fn) fn = REAL(int (*)(const char *, const char *, const struct addrinfo *, struct addrinfo **), "getaddrinfo");
    return fn(h, s, hints, res);
}
struct hostent *fence_gethostbyname(const char *n) __asm__("_gethostbyname");
struct hostent *fence_gethostbyname(const char *n) {
    if (!net_ok("gethostbyname")) return NULL;
    static struct hostent *(*fn)(const char *);
    if (!fn) fn = REAL(struct hostent *(*)(const char *), "gethostbyname");
    return fn(n);
}
struct hostent *fence_gethostbyaddr(const void *a, socklen_t l, int t) __asm__("_gethostbyaddr");
struct hostent *fence_gethostbyaddr(const void *a, socklen_t l, int t) {
    if (!net_ok("gethostbyaddr")) return NULL;
    static struct hostent *(*fn)(const void *, socklen_t, int);
    if (!fn) fn = REAL(struct hostent *(*)(const void *, socklen_t, int), "gethostbyaddr");
    return fn(a, l, t);
}
