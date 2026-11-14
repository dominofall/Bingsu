# rgss-check: 결과 폴더 → markdown 표 (tools/rgss-check/report.rb)
#
#   ruby report.rb <결과 폴더> [<비교할 결과 폴더> ...]  > report.md
#
# 결과 폴더 구조 (rgss-check.sh 가 만든다): <게임>/scan.json, <게임>/ruby-<프로필>/{meta.json,app.log,engine.log,shot1.png,shot2.png}
# 여러 폴더를 주면 (예: 고친 빌드·고치기 전 빌드) 한 표에 빌드 이름(label)으로 나란히 적는다.
require "json"

dirs = ARGV.empty? ? abort("usage: ruby report.rb <결과 폴더>...") : ARGV

def read(p) = (File.read(p, encoding: "UTF-8").scrub rescue "")

def judge(dir)
  meta = JSON.parse(read(File.join(dir, "meta.json")))
  app = read(File.join(dir, "app.log"))
  eng = read(File.join(dir, "engine.log"))
  r = { "meta" => meta, "dir" => dir }
  r["ruby_used"] = eng[/^\[RUBY\] \(main\.cpp\) (\S+)/, 1] || app[/ruby=(\d+)/, 1]
  r["scres"] = eng[/scRes=(\d+x\d+)/, 1]
  r["probe_ruby"] = eng[/\[rgss-check\] probe ruby=(\S+)/, 1]
  r["toplevel_public"] = eng[/toplevel_def_public=(\w+)/, 1]
  r["resizes"] = eng.scan(/\[rgss-check\] resize_screen ([\d.]+x[\d.]+)/).flatten
  # screen <엔진>x<엔진> game=<게임이 보는 값> (예전 probe 는 game= 없이 게임이 보는 값만)
  shots = eng.scan(/\[rgss-check\] screen (\S+)(?: game=(\S+))?/)
  r["screens"] = shots.map { |e, g| g ? e : nil }.compact
  r["game_screens"] = shots.map { |e, g| g || e }
  r["aspect"] = app.scan(/게임 화면 비율 ([\d.]+)/).flatten.last
  errs = app.scan(/엔진 오류: (.*)$/).flatten.map(&:strip)
  # 앱 로그에 안 잡힌 경우 엔진 로그의 Ruby 예외 줄
  if errs.empty?
    errs = eng.lines.grep(/\[(ERROR|EXCEPTION)\]|Error\)|\(NameError|NoMethodError|SyntaxError|TypeError|ArgumentError/)
              .reject { |l| l =~ /casefold|rgss-check/ }.map(&:strip).first(2)
  end
  r["errors"] = errs.uniq
  # 엔진이 문법 오류로 건너뛴 스크립트 (Ruby 3.1 에서 옛 문법)
  r["skipped"] = eng.scan(/\[SKIPPED\] \(binding-mri\.cpp \[C\+\+\]\) Script '([^']+)': (\w+) - (.*)$/)
                   .map { |n, k, msg| "#{n} (#{k}: #{msg.sub(/\A\d+:[^:]+:/, '').strip[0, 60]})" }.uniq
  r["ended"] = app[/엔진 끝남 clean=(\w+)/, 1]
  # 빙수 자신이 한 일: 화면 크기 맞춤(screenFitScript), 스크립트 문법으로 옛 Ruby 고름(RubyScriptScan)
  r["fit"] = eng[/\[bingsu\] screen fit (\S+ -> \S+)/, 1]
  r["legacy_pick"] = app[/스크립트가 Ruby 1\.8 문법 \((\d+)곳/, 1]
  r["started"] = !r["screens"].empty? || !!r["aspect"] || eng.include?("[INFO] (graphics-init)")
  r["ruby_started"] = eng.include?("[RUBY] (main.cpp)")
  r["shots"] = %w[shot1.png shot2.png].map { |s| File.join(dir, s) }.select { |p| File.exist?(p) }
  r
end

def declared_size(scan)
  d = scan["declared"] || []
  pick = d.find { |x| x["from"] !~ /mkxp/ && x["w"] && x["h"] } || d.find { |x| x["w"] && x["h"] }
  pick && "#{pick['w']}x#{pick['h']}"
end

rows = []
games = {}
dirs.each do |out|
  Dir.glob(File.join(out, "*", "scan.json")).sort.each do |sp|
    gdir = File.dirname(sp)
    scan = JSON.parse(read(sp))
    games[File.basename(gdir)] ||= scan
    Dir.glob(File.join(gdir, "ruby-*")).sort.each do |rd|
      next unless File.exist?(File.join(rd, "meta.json"))
      rows << [File.basename(gdir), scan, judge(rd)]
    end
  end
end

rgss_name = { 1 => "XP", 2 => "VX", 3 => "VX Ace" }
puts "# rgss-check 결과"
puts
puts "만든 때: #{Time.now.strftime('%Y-%m-%d %H:%M')} · 결과 폴더: #{dirs.map { |d| "`#{d}`" }.join(', ')}"
puts
puts "| 게임 | RGSS | 빌드 | Ruby (자동=*) | 시작 | 오류·건너뛴 스크립트 | 엔진 해상도 → 실제 화면 | 게임이 밝힌 크기 | 일치 | 맨 위 def 공개 | 스크린숏 |"
puts "|---|---|---|---|---|---|---|---|---|---|---|"
rows.each do |slug, scan, r|
  m = r["meta"]
  decl = declared_size(scan)
  final = r["screens"].last
  seen = r["game_screens"].last
  match =
    if final.nil? || decl.nil? then "?"
    elsif final == decl then "✓"
    else "✗"
    end
  started =
    if !r["errors"].empty? then "오류로 멈춤"
    elsif r["ended"] then "끝남(#{r['ended']})"
    elsif !r["game_screens"].empty? then "✓"
    elsif r["ruby_started"] && !r["probe_ruby"] then "✓ (측정 없음)"
    elsif r["ruby_started"] then "Ruby 만 (화면 신호 없음)"
    elsif r["started"] then "여는 중 (시간 안에 Ruby 시작 안 함)"
    else "✗"
    end
  err = r["errors"].map { |e| e.gsub("|", "\\|")[0, 140] }.join("<br>")
  unless r["skipped"].empty?
    err += "<br>" unless err.empty?
    err += "건너뛴 스크립트 #{r['skipped'].size}: " + r["skipped"].first(3).map { |x| x.gsub("|", "\\|") }.join(", ")
  end
  err = "-" if err.empty?
  reso = [r["scres"] || "?", final].compact.join(" → ")
  reso += " (게임이 보는 값 #{seen})" if seen && seen != final
  reso += " (resize #{r['resizes'].uniq.join(',')})" unless r["resizes"].empty?
  reso += " (빙수가 맞춤 #{r['fit']})" if r["fit"]
  ruby = m["profile"] + (m["profile"] == m["auto"] ? "*" : "")
  ruby += " (#{r['probe_ruby']})" if r["probe_ruby"]
  ruby += " ← 스크립트 문법으로 고름" if r["legacy_pick"]
  shots = r["shots"].map { |p| "[#{File.basename(p, '.png')}](#{p})" }.join(" ")
  puts "| #{slug} | #{rgss_name[scan['rgss']]}#{scan['encrypted'] ? ' 🔒' : ''} | #{m['label']} | #{ruby} | #{started} | #{err} | #{reso} | #{decl || '-'} | #{match} | #{r['toplevel_public'] || '-'} | #{shots} |"
end
puts
puts "- 시작: ✓ = probe 가 게임 화면 크기를 읽음(게임 스크립트가 Graphics.update 까지 감), ✓ (측정 없음) = Ruby 는 돌았고 probe 를 못 넣은 게임(스크린숏으로 확인), 여는 중 = 기다린 시간 안에 Ruby 가 시작되지 않음(--t1/--t2 를 늘려 다시)."
puts "- 실제 화면: probe.rb 가 게임 스크립트보다 먼저 잡아 둔 엔진의 `Graphics.width/height` 를 30프레임마다 읽은 마지막 값. 게임이 Graphics.width 를 덮어써 다른 값을 보면 괄호로 적는다. mkxp.json 이 없는 게임은 probe 를 넣지 않아 비어 있다."
puts "- 게임이 밝힌 크기: 스크립트의 DEFAULTSCREENWIDTH/HEIGHT 또는 Settings SCREEN_WIDTH/HEIGHT (없으면 mkxp.json defScreenW/H)."
puts "- 🔒 = 스크립트가 암호화 아카이브 안에 있어 정적 검사·밝힌 크기를 못 읽음."
puts
puts "## Ruby 버전 차이 위험 코드 (정적 검색)"
puts
games.each do |slug, scan|
  risks = (scan["risks"] || []).reject { |x| x["level"] == "info" }
  next if risks.empty?
  puts "### #{slug}"
  puts
  risks.each do |x|
    puts "- **#{x['key']}** (#{x['level']}, #{x['count']}곳) — #{x['why']}"
    x["examples"].first(3).each { |e| puts "  - `#{e.gsub('`', "'")}`" }
  end
  puts
end
