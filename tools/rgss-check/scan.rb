# rgss-check: 게임 폴더를 읽기만 해서 알아낼 수 있는 것 (tools/rgss-check/scan.rb)
#
#   ruby scan.rb <게임 폴더>   → JSON 한 줄 (stdout)
#
# - RGSS 판(XP=1·VX=2·VX Ace=3)과 빙수 자동 Ruby 프로필 (RubyProfile.detect 와 같은 규칙)
# - 게임이 밝힌 화면 크기: mkxp.json defScreenW/H, 스크립트의 DEFAULTSCREENWIDTH/HEIGHT,
#   Settings::SCREEN_WIDTH/HEIGHT, Graphics.resize_screen(숫자, 숫자)
# - Ruby 1.8/1.9 → 3.1 에서 뜻이 달라지는 코드 모양 (정적 검색, 거짓 양성 있음)
# 스크립트는 Data/Scripts.rxdata·rvdata·rvdata2 (+ Essentials PluginScripts.rxdata, Data/Scripts/ 폴더)를 Marshal·zlib 로 푼다.
# 암호화 아카이브(Game.rgssad/rgss2a/rgss3a) 안 스크립트는 읽지 않는다 → encrypted=true.
require "json"
require "zlib"

folder = ARGV[0] or abort "usage: ruby scan.rb <게임 폴더>"
names = Dir.children(folder) rescue []
lower = names.map(&:downcase)
data_dir = names.find { |n| n.casecmp?("Data") }
data_names = data_dir ? (Dir.children(File.join(folder, data_dir)) rescue []) : []
dl = data_names.map(&:downcase)

rgss =
  if lower.include?("game.rgss3a") || dl.include?("scripts.rvdata2") then 3
  elsif lower.include?("game.rgss2a") || dl.include?("scripts.rvdata") then 2
  else 1
  end
modern = lower.include?("mkxp.json") || lower.any? { |n| n.start_with?("x64-msvcrt-ruby3") }
encrypted = lower.any? { |n| n =~ /\Agame\.rgss(ad|2a|3a)\z/ }

# mkxp.json (// 주석 줄 빼고 — 빙수 installOverlay 와 같은 방식)
mk = {}
if (mkn = names.find { |n| n.casecmp?("mkxp.json") })
  text = File.read(File.join(folder, mkn), encoding: "UTF-8") rescue ""
  stripped = text.lines.reject { |l| l.strip.start_with?("//") }.join
  mk = (JSON.parse(stripped.gsub(/,(\s*[}\]])/, '\1')) rescue {})
end

# 스크립트 모으기: [[이름, 코드], ...]
scripts = []
inflate = lambda do |s|
  next nil unless s.is_a?(String) && s.bytesize > 2
  begin
    Zlib::Inflate.inflate(s).force_encoding("UTF-8").scrub
  rescue StandardError
    nil
  end
end
walk = lambda do |obj, label|
  case obj
  when Array
    # Scripts.*data 한 줄: [id, 이름, zlib] / PluginScripts: [플러그인, meta, [[파일, zlib], ...]]
    name = obj.find { |x| x.is_a?(String) && x.bytesize < 200 && inflate.(x).nil? }
    obj.each do |x|
      if x.is_a?(String) && (code = inflate.(x))
        scripts << ["#{label}#{name.to_s.dup.force_encoding('UTF-8').scrub}", code]
      elsif x.is_a?(Array)
        walk.(x, name ? "#{label}#{name.to_s.dup.force_encoding('UTF-8').scrub}/" : label)
      end
    end
  end
end
%w[scripts.rxdata scripts.rvdata scripts.rvdata2 pluginscripts.rxdata].each do |want|
  hit = data_names.find { |n| n.downcase == want } or next
  begin
    obj = Marshal.load(File.binread(File.join(folder, data_dir, hit)))
    walk.(obj, want.start_with?("plugin") ? "Plugin:" : "")
  rescue StandardError, TypeError, ArgumentError => e
    scripts << ["#{hit}(읽기 실패: #{e.class})", ""]
  end
end
# 스크립트 폴더로 나뉜 게임 (Data/Scripts/**.rb, Essentials v20+ 의 Plugins/**.rb)
[[data_dir, "Scripts"], [nil, "Plugins"]].each do |a, b|
  base = File.join(*[folder, a, b].compact)
  next unless File.directory?(base)
  Dir.glob(File.join(base, "**", "*.rb")).sort.each do |f|
    scripts << [f.sub(folder + "/", ""), (File.read(f, encoding: "UTF-8").scrub rescue "")]
  end
end

# 빙수 RubyScriptScan(BrassBowl/RGSSProbe.swift)과 같은 규칙: 1.8 전용 문법(`when x:`, rescue 밖 retry)이 있고
# 신형 문법(&. -> 키워드 인자 {a: 1})이 없으면 mkxp.json 이 있어도 옛 Ruby
WHEN_COLON = /^\s*when\s+(?:[^\s:"',#]+|"[^"]*"|'[^']*')(?:\s*,\s*(?:[^\s:"',#]+|"[^"]*"|'[^']*'))*:(?:\s|$)/
MODERN_SYNTAX = [/&\.[a-z_]/, /->\s*[({]/, /^\s*def\s+[\w.?!]+\s*\([^)]*\b[a-z_]\w*:(?!:)/, /\{\s*[a-z_]\w*:\s/]
def indent_of(l) = l[/\A[ \t]*/].gsub("\t", "  ").size
def retry_outside_rescue?(lines, at)
  cur = indent_of(lines[at]); j = at - 1
  while j >= 0
    l = lines[j]; t = l.strip; j -= 1
    next if t.empty? || t.start_with?("#")
    d = indent_of(l)
    next unless d < cur
    return false if t == "rescue" || t.start_with?("rescue ") || t.start_with?("rescue=")
    return true if t.start_with?("def ")
    cur = d
  end
  true
end
legacy_syntax = 0; modern_syntax = 0
scripts.each do |_, code|
  lines = code.lines
  lines.each_with_index do |raw, i|
    line = (h = raw.index("#")) && raw[0...h] !~ /["']/ ? raw[0...h] : raw
    legacy_syntax += 1 if line =~ WHEN_COLON
    legacy_syntax += 1 if line =~ /\bretry\b/ && retry_outside_rescue?(lines, i)
    modern_syntax += 1 if MODERN_SYNTAX.any? { |re| line =~ re }
  end
end
legacy_only = legacy_syntax > 0 && modern_syntax == 0
auto = (modern && !legacy_only) ? "31" : (rgss == 3 ? "19" : "18")

# 게임이 밝힌 화면 크기
declared = []
declared << { "from" => "mkxp.json", "w" => mk["defScreenW"], "h" => mk["defScreenH"] } if mk["defScreenW"] || mk["defScreenH"]
size_pats = [
  [/^\s*DEFAULTSCREENWIDTH\s*=\s*(\d+)/, /^\s*DEFAULTSCREENHEIGHT\s*=\s*(\d+)/, "DEFAULTSCREEN"],
  [/^\s*SCREEN_WIDTH\s*=\s*(\d+)/, /^\s*SCREEN_HEIGHT\s*=\s*(\d+)/, "SCREEN_WIDTH"],
]
resize_calls = []
scripts.each do |name, code|
  size_pats.each do |wp, hp, tag|
    w = code[wp, 1]; h = code[hp, 1]
    declared << { "from" => "#{tag} (#{name})", "w" => w&.to_i, "h" => h&.to_i } if w || h
  end
  code.scan(/Graphics\.resize_screen\(\s*(\d+)\s*,\s*(\d+)\s*\)/) { |w, h| resize_calls << "#{w}x#{h} (#{name})" }
end

# Ruby 1.8/1.9 → 3.1 차이가 드러나는 코드 모양 (정적 검색)
RISKS = [
  ["toplevel-respond_to", "high",
   /\b(Kernel|Object)\.respond_to\?\(?\s*[:"']/,
   "맨 위 def 는 3.1 에서 비공개 → respond_to? 거짓 (포켓몬 Z 화면 크기 원인)"],
  ["methods-include-string", "high",
   /\b(instance_methods|public_instance_methods|private_instance_methods|methods|public_methods|private_methods|singleton_methods|constants|instance_variables|global_variables|local_variables|class_variables)\b(\(\w*\))?\.include\?\(\s*["']/,
   "1.8 은 문자열 배열, 1.9+ 는 심볼 배열 → include?(\"이름\") 거짓"],
  ["proc-new-no-block", "high", /\bProc\.new\b(?!\s*(\{|do\b|\(\s*&))/, "블록 없는 Proc.new 는 3.0 에서 오류"],
  ["kcode-iconv-jcode", "mid", /\$KCODE|\bIconv\b|require\s*\(?\s*["']jcode/, "1.8 문자 인코딩 API (3.1 에 없음)"],
  ["string-each", "mid", /["']\s*\.each\s*(\{|do\b)|\.each_char_with_index/, "String#each 는 1.9 에서 없어짐"],
  ["hash-index", "low", /\{[^}]*\}\.index\(|@\w*hash\w*\.index\(/i, "Hash#index 는 key 로 바뀜 (3.0 에서 없어짐)"],
  ["safe-taint", "low", /\$SAFE\b|\.(taint|untaint|tainted\?)\b/, "3.1 경고만 (3.2 에서 없어짐)"],
  ["file-exists", "low", /\b(File|Dir|FileTest)\.exists\?/, "3.1 경고만 (3.2 에서 없어짐)"],
  ["fixnum-bignum", "low", /\b(Fixnum|Bignum)\b/, "3.1 경고만 (3.2 에서 없어짐), Integer 로 합쳐짐"],
  ["when-colon", "mid", /^\s*when\s+([^\s:"',#]+|"[^"]*"|'[^']*'):(\s|$)/, "1.8 의 'when x: 문장' 은 1.9+ 문법 오류"],
  ["win32api", "info", /\bWin32API\b|\bDL\b::|Fiddle/, "엔진 win32_wrap 이 흉내 (호출 종류별로 확인 필요)"],
]
risks = []
RISKS.each do |key, level, re, why|
  hits = []
  scripts.each do |name, code|
    code.each_line.with_index do |line, i|
      next if line.lstrip.start_with?("#")
      hits << "#{name}:#{i + 1}: #{line.strip[0, 120]}" if line =~ re
    end
  end
  next if hits.empty?
  risks << { "key" => key, "level" => level, "why" => why, "count" => hits.size, "examples" => hits.first(5) }
end

# 신형 Ruby 문법으로 컴파일해 보기: 엔진은 Ruby 3.1 에서 문법 오류가 난 스크립트를 통째로 건너뛴다([SKIPPED]).
# 그러면 그 안의 클래스·함수가 없어 뒤 스크립트가 NameError 로 멈춘다(포켓몬 Z 원본: PScreen_Load 의 'Invalid retry').
# 이 컴퓨터의 Ruby(3.1 보다 새것)로 검사하므로 3.1 과 조금 다를 수 있다
syntax = []
old_verbose = $VERBOSE
$VERBOSE = nil
scripts.each do |name, code|
  next if code.empty?
  begin
    RubyVM::InstructionSequence.compile(code, name)
  rescue SyntaxError => e
    msg = e.message.lines.map(&:strip).reject(&:empty?)
    first = msg.find { |l| l =~ /:\d+:/ } || msg.first
    syntax << "#{name}: #{first.to_s.sub(/\A.*?#{Regexp.escape(name)}:/, 'line ')[0, 160]}"
  end
end
$VERBOSE = old_verbose
unless syntax.empty?
  risks.unshift({ "key" => "syntax-error-modern", "level" => "high", "count" => syntax.size,
                  "why" => "신형 Ruby 에서 문법 오류 → Ruby 3.1 로 돌리면 엔진이 이 스크립트를 통째로 건너뜀 (검사: 이 컴퓨터 Ruby #{RUBY_VERSION})",
                  "examples" => syntax.first(8) })
end

puts JSON.generate({
  "folder" => folder, "rgss" => rgss, "auto" => auto, "modern" => modern, "encrypted" => encrypted,
  "legacy_syntax" => legacy_syntax, "modern_syntax" => modern_syntax,
  "scripts" => scripts.size, "declared" => declared, "resize_calls" => resize_calls.uniq.first(10),
  "has_pbSetResizeFactor" => scripts.any? { |_, c| c.include?("pbSetResizeFactor") },
  "risks" => risks,
})
