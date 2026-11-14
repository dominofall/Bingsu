# rgss-check 측정 스크립트 (tools/rgss-check/probe.rb)
#
# 점검용 복제본의 mkxp.json preloadScript 에만 넣는다(원본 게임 폴더는 건드리지 않음).
# 게임 스크립트보다 먼저 돌며, 엔진 디버그 로그(brassbowl.log)에 "[rgss-check] ..." 줄을 남긴다:
#   probe ruby=..            지금 돌고 있는 Ruby
#   toplevel_def_public=..   맨 위 def 가 RGSS 처럼 공개인지 (Ruby 3.1 차이 1번)
#   resize_screen WxH        게임이 Graphics.resize_screen 을 부를 때마다
#   screen WxH game=WxH frame=N
#                            엔진의 실제 화면 크기(게임 스크립트가 덮어쓰기 전에 잡아 둔 Graphics.width/height)와
#                            게임이 보는 Graphics.width/height (Essentials 는 이것을 DEFAULTSCREENWIDTH 로 덮어쓰기도 함).
#                            바뀔 때만, 30프레임마다 봄
# Ruby 1.8 게임에도 읽히므로 문법은 1.8 안에서만 쓴다.

module RgssCheckProbe
  @last = nil
  @n = 0
  # 게임이 Graphics.width 를 다시 정의해도 엔진 값을 읽을 수 있게 지금 잡아 둔다
  @w = (Graphics.method(:width) rescue nil)
  @h = (Graphics.method(:height) rescue nil)

  def self.say(msg)
    line = "[rgss-check] " + msg.to_s
    if defined?(System) && System.respond_to?(:puts)
      System.puts(line)
    else
      $stderr.puts(line)
    end
  rescue Exception
  end

  def self.tick
    @n += 1
    return unless @n % 30 == 1
    eng = @w && @h ? "#{@w.call}x#{@h.call}" : "?"
    s = "#{eng} game=#{Graphics.width}x#{Graphics.height}"
    if s != @last
      @last = s
      say("screen #{s} frame=#{@n}")
    end
  rescue Exception
  end
end

def rgss_check_toplevel_probe; end

RgssCheckProbe.say("probe ruby=#{RUBY_VERSION}")
begin
  RgssCheckProbe.say("toplevel_def_public=#{Kernel.respond_to?(:rgss_check_toplevel_probe)}")
rescue Exception
end

class << Graphics
  alias_method :rgss_check_update, :update
  def update(*a)
    RgssCheckProbe.tick
    rgss_check_update(*a)
  end

  if method_defined?(:resize_screen)
    alias_method :rgss_check_resize_screen, :resize_screen
    def resize_screen(*a)
      RgssCheckProbe.say("resize_screen #{a.join('x')}")
      rgss_check_resize_screen(*a)
    end
  end
end
