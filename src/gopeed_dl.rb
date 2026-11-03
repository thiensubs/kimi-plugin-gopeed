# gopeed-dl: talk to a Gopeed download manager through its REST API.
#
# Config from the environment:
#   GOPEED_URL    endpoint: http(s)://host:port (default http://127.0.0.1:9999)
#                 or unix:///path/to/gopeed.sock (desktop app in Unix mode).
#                 If unset, endpoints are auto-detected: unix sockets first,
#                 then the standard TCP port. If set, it is used strictly.
#   GOPEED_TOKEN  API token, sent as the X-Api-Token header (TCP only;
#                 the unix socket is guarded by file permissions instead)
#   GOPEED_SOCK   extra unix-socket path to try (doctor/auto mode)
#   GOPEED_APP    override for the Gopeed .app/binary path (doctor/start);
#                 without it, standard install locations and PATH are searched
#
# Commands:
#   gopeed-dl doctor                          # app present? API up?
#   gopeed-dl start                           # launch GOPEED_APP, wait for API
#   gopeed-dl ping
#   gopeed-dl add <url> [--name FILE] [--dir DIR]
#   gopeed-dl list
#   gopeed-dl status <id>
#   gopeed-dl wait <id> [--timeout SECONDS]   (default 600)
#   gopeed-dl pause <id> | continue <id>
#   gopeed-dl remove <id> [--force]
#
# Written for the Spinel AOT subset: no eval, no metaprogramming, plain defs.

require "json"
require "net/http"
require "net/https"
require "uri"

# Heap self-check, same idea as the C plugins' malloc counters: after a full GC,
# whatever is still on the heap is retained, not garbage. Registered at the top so
# it also runs on error paths (an at_exit below `main` never registers when main
# calls exit). Runs when GOPEEDSELFCHECK=1, or on every 10th process (pid % 10).
def self_check
  GC.start
  bytes = GC.stat(:bytes)
  str_bytes = GC.stat(:str_bytes)
  cycles = GC.stat(:cycle)
  STDERR.puts "gopeed-dl self-check: heap_bytes=#{bytes} str_bytes=#{str_bytes} cycles=#{cycles}"
  if bytes > 4 * 1024 * 1024
    STDERR.puts "gopeed-dl self-check: WARNING retained heap #{bytes} bytes after full GC (> 4 MiB)"
  end
end

at_exit do
  if ENV["GOPEEDSELFCHECK"] == "1" || Process.pid % 10 == 0
    begin
      self_check
    rescue => e
      STDERR.puts "gopeed-dl self-check failed: #{e.message}"
    end
  end
end

TOKEN = ENV["GOPEED_TOKEN"]
DEFAULT_TCP = "http://127.0.0.1:9999"

def base_url
  ENV["GOPEED_URL"]
end

# Unix-socket REST endpoints. Verified on Gopeed v1.9.3: with the desktop
# app at Settings -> Advanced -> Protocol "Unix", the full REST API answers
# on ~/Library/Caches/gopeed.sock (macOS) or $XDG_CACHE_HOME/gopeed.sock
# (Linux) with no token. The gopeed_host.sock in Application Support is the
# browser-extension channel and has NO REST routes ("Route not found").
def candidate_socket_paths
  list = []
  custom = ENV["GOPEED_SOCK"]
  list << custom if custom && !custom.empty?
  home = ENV["HOME"] || ""
  list << home + "/Library/Caches/gopeed.sock"
  xdg = ENV["XDG_CACHE_HOME"] || (home + "/.cache")
  list << xdg + "/gopeed.sock"
  list.select { |p| File.exist?(p) }
end

# Endpoints to try, in order. An explicit GOPEED_URL is strict (one entry);
# without it we auto-detect: unix sockets first (desktop-app default), then
# the standard TCP port used by gopeed-web / Protocol TCP.
def endpoints
  b = base_url
  if b && !b.empty?
    return [b]
  end
  eps = candidate_socket_paths.map { |p| "unix://" + p }
  eps << DEFAULT_TCP
  eps
end

# Where a Gopeed app/binary may live on a real machine, most native first.
# GOPEED_APP always wins; then the standard install spots per OS; then PATH.
def candidate_app_paths
  list = []
  custom = ENV["GOPEED_APP"]
  list << custom if custom && !custom.empty?
  home = ENV["HOME"] || ""
  list << "/Applications/Gopeed.app"                                   # macOS, 1st
  list << home + "/Applications/Gopeed.app"                            # macOS, user Applications
  list << "/usr/local/bin/gopeed" << "/usr/bin/gopeed"                 # Linux package managers
  list << "/opt/homebrew/bin/gopeed"                                   # macOS Homebrew (Intel + ARM)
  list << home + "/.local/bin/gopeed"                                  # Linux user install
  list << home + "/.local/share/flatpak/exports/bin/com.gopeed.Gopeed" # Linux flatpak
  list << home + "/Applications/Gopeed.AppImage"                       # Linux AppImage
  la = ENV["LOCALAPPDATA"]
  list << la + "\\Programs\\Gopeed\\gopeed.exe" if la                 # Windows per-user
  list << "C:\\Program Files\\Gopeed\\gopeed.exe"                     # Windows machine-wide
  (ENV["PATH"] || "").split(/[:;]/).each do |dir|                     # anywhere on PATH
    list << dir + "/gopeed" << dir + "/gopeed-web" << dir + "/gopeed.exe"
  end
  list
end

def app_path
  candidate_app_paths.each do |p|
    return p if File.exist?(p)
  end
  nil
end

def request_path(uri)
  p = uri.path
  p = "/" if p.nil? || p.empty?
  q = uri.query
  if q && !q.empty?
    p + "?" + q
  else
    p
  end
end

# Read everything the peer sends until it closes (or the deadline passes).
def read_all(s, deadline)
  res = +""
  loop do
    wait = deadline - Time.now
    break if wait <= 0
    if IO.select([s], nil, nil, wait)
      begin
        res << s.readpartial(65536)
      rescue EOFError
        break
      end
    else
      break
    end
  end
  res
end

def dechunk(s)
  out = +""
  rest = s
  while rest && !rest.empty?
    line, rest = rest.split("\r\n", 2)
    size = line.to_s.strip.to_i(16)
    break if size == 0
    out << rest[0, size].to_s
    rest = rest[(size + 2)..] || ""
  end
  out
end

# Minimal HTTP/1.1 request over a UNIX socket. Returns [status_code, body].
def unix_http(sock_path, method, rpath, body)
  require "socket"
  s = UNIXSocket.new(sock_path)
  raw = ""
  begin
    payload = body.nil? ? nil : JSON.generate(body)
    req = "#{method} #{rpath} HTTP/1.1\r\nHost: gopeed\r\nConnection: close\r\n"
    req += "Content-Type: application/json\r\n"
    if TOKEN && !TOKEN.empty?
      req += "X-Api-Token: #{TOKEN}\r\n"
    end
    if payload
      req += "Content-Length: #{payload.bytesize}\r\n\r\n#{payload}"
    else
      req += "\r\n"
    end
    s.write(req)
    raw = read_all(s, Time.now + 30)
  ensure
    begin
      s.close
    rescue
    end
  end
  head, rest = raw.split("\r\n\r\n", 2)
  return [0, ""] if head.nil?
  lines = head.split("\r\n")
  status = lines[0].to_s.split(" ")[1].to_i
  headers = {}
  i = 1
  while i < lines.length
    k, v = lines[i].split(":", 2)
    headers[k.to_s.downcase] = v.to_s.strip if k && v
    i += 1
  end
  body_str = rest.to_s
  if headers["transfer-encoding"].to_s.include?("chunked")
    body_str = dechunk(body_str)
  elsif headers["content-length"]
    body_str = body_str[0, headers["content-length"].to_i].to_s
  end
  [status, body_str]
end

# One HTTP call to one endpoint (http(s):// or unix://). Returns [status, body].
def http_call(endpoint, method, path, body)
  if endpoint.start_with?("unix://")
    return unix_http(endpoint["unix://".length..], method, path, body)
  end
  uri = URI.parse(endpoint + path)
  http = Net::HTTP.new(uri.host, uri.port)
  http.open_timeout = 5
  http.read_timeout = 30
  http.use_ssl = true if uri.scheme == "https"
  req = case method
        when "GET"    then Net::HTTP::Get.new(request_path(uri))
        when "POST"   then Net::HTTP::Post.new(request_path(uri))
        when "PUT"    then Net::HTTP::Put.new(request_path(uri))
        when "PATCH"  then Net::HTTP::Patch.new(request_path(uri))
        when "DELETE" then Net::HTTP::Delete.new(request_path(uri))
        else raise "unsupported method #{method}"
        end
  req["Content-Type"] = "application/json"
  if TOKEN && !TOKEN.empty?
    req["X-Api-Token"] = TOKEN
  end
  req.body = JSON.generate(body) unless body.nil?
  res = http.request(req)
  [res.code.to_i, res.body.to_s]
end

# One call to the Gopeed API. Tries each endpoint until one answers with the
# {code, msg, data} envelope; returns its "data". An endpoint that answers but
# rejects us (bad token, plain-text error) raises immediately — we do not
# silently fall through to another endpoint. Raises on total failure.
def api(method, path, body = nil)
  last_err = nil
  eps = endpoints
  eps.each do |ep|
    begin
      status, raw = http_call(ep, method, path, body)
    rescue => e
      last_err = e
      next
    end
    parsed = nil
    begin
      parsed = JSON.parse(raw)
    rescue
      parsed = nil
    end
    if parsed.is_a?(Hash) && parsed.key?("code")
      code = parsed["code"]
      unless code == 0
        raise "gopeed error: #{parsed["msg"]} (code #{code}, HTTP #{status})"
      end
      return parsed["data"]
    end
    snippet = raw[0, 120]
    raise "gopeed answered HTTP #{status} (not a JSON API reply): #{snippet}"
  end
  hint = "Start Gopeed with its API on: app Settings -> Advanced -> Protocol TCP port 9999 (or leave Protocol Unix and let gopeed-dl use the socket), headless: gopeed-web -A 127.0.0.1 -P 9999. Run 'gopeed-dl doctor' to check."
  app = app_path
  if app
    hint = "Gopeed found at #{app} but no API answered. #{hint}"
  end
  raise "cannot reach gopeed at #{eps.join(" , ")} (#{last_err ? last_err.message : "no endpoint"}). #{hint}"
end

# Task ids go into the URL path, so keep them to a safe alphabet. This also
# makes a missing id fail locally instead of hitting DELETE /api/v1/tasks
# (the collection route), which would remove every task.
def check_id(id)
  if id.nil? || id.empty?
    raise "missing task id"
  end
  unless id =~ /\A[A-Za-z0-9_-]+\z/
    raise "invalid task id: #{id}"
  end
  id
end

def fmt_bytes(n)
  f = n.to_f
  if f >= 1073741824.0
    "#{(f / 1073741824.0).round(1)} GB"
  elsif f >= 1048576.0
    "#{(f / 1048576.0).round(1)} MB"
  elsif f >= 1024.0
    "#{(f / 1024.0).round(1)} KB"
  else
    "#{f.to_i} B"
  end
end

# Real Gopeed puts the total in meta.res.size (top-level "size" can be null)
# and the true byte count in progress.downloaded ("used" is an internal counter).
def task_size(t)
  s = t["size"]
  if s.nil?
    meta = t["meta"]
    if meta && meta["res"]
      s = meta["res"]["size"]
    end
  end
  s || 0
end

def task_downloaded(t)
  prog = t["progress"] || {}
  d = prog["downloaded"]
  d = prog["used"] if d.nil?
  d || 0
end

def pct(task)
  size = task_size(task)
  used = task_downloaded(task)
  if size > 0
    (used.to_f * 100.0 / size.to_f).round
  else
    0
  end
end

def print_task(t)
  prog = t["progress"] || {}
  puts "id:       #{t["id"]}"
  puts "name:     #{t["name"]}"
  puts "status:   #{t["status"]}"
  puts "progress: #{pct(t)}%  #{fmt_bytes(task_downloaded(t))} / #{fmt_bytes(task_size(t))}"
  puts "speed:    #{fmt_bytes(prog["speed"] || 0)}/s"
  opts = (t["meta"] || {})["opts"] || {}
  if opts["path"]
    puts "dir:      #{opts["path"]}"
  end
end

def cmd_ping
  info = api("GET", "/api/v1/info")
  puts "gopeed #{info["version"]} running on #{info["os"]}/#{info["arch"]} (endpoint #{endpoints.join(", ")})"
end

# doctor: is a Gopeed app/binary present, which endpoints answer, token state?
def cmd_doctor
  app = app_path
  if app.nil?
    puts "app:  not found in standard locations — set GOPEED_APP to your Gopeed .app or gopeed-web binary"
  else
    puts "app:  #{app} (found)"
  end
  if TOKEN && !TOKEN.empty?
    puts "token: set from GOPEED_TOKEN (sent as X-Api-Token, never printed)"
  else
    puts "token: not set — fine on a unix socket; required if the TCP API has a token"
  end
  ok = false
  endpoints.each do |ep|
    begin
      status, raw = http_call(ep, "GET", "/api/v1/info", nil)
      parsed = nil
      begin
        parsed = JSON.parse(raw)
      rescue
        parsed = nil
      end
      if parsed.is_a?(Hash) && parsed["code"] == 0
        d = parsed["data"] || {}
        puts "api:  #{ep} -> gopeed #{d["version"]} on #{d["os"]}/#{d["arch"]} — OK"
        ok = true
      else
        puts "api:  #{ep} -> answered HTTP #{status}, but not the Gopeed REST API"
      end
    rescue => e
      puts "api:  #{ep} -> not reachable (#{e.message})"
    end
  end
  if ok
    puts "hint: pin one endpoint with GOPEED_URL (http://127.0.0.1:9999 or unix:///path/to/gopeed.sock); set it to empty to auto-detect again"
  else
    puts "      nothing answered. Start Gopeed with the API on (app: Advanced -> Protocol TCP, port 9999; or run 'gopeed-dl start'; headless: gopeed-web -A 127.0.0.1 -P 9999)"
    exit 1
  end
end

# start: launch the Gopeed app (.app on macOS) or headless binary found/overridden
def cmd_start
  app = app_path
  if app.nil?
    raise "no Gopeed found — set GOPEED_APP to the .app or gopeed-web binary"
  end
  target = base_url
  if target.nil? || target.empty? || target.start_with?("unix://")
    target = DEFAULT_TCP
  end
  ENV["GOPEED_URL"] = target
  buri = URI.parse(target)
  if ENV["OS"] == "Windows_NT"
    system("cmd /c start \"\" \"#{app}\" -A #{buri.host} -P #{buri.port}")
  elsif app.end_with?(".app")
    system("open", app)
  else
    system("nohup \"#{app}\" -A #{buri.host} -P #{buri.port} >/dev/null 2>&1 &")
  end
  puts "launched #{app}, waiting for the API at #{target} ..."
  i = 0
  while i < 15
    begin
      api("GET", "/api/v1/info")
      puts "api is up at #{target}"
      return
    rescue
      sleep 1
    end
    i += 1
  end
  raise "API did not come up at #{target} within 15s — run 'gopeed-dl doctor'"
end

def cmd_add(url, rest)
  if url.nil? || url.empty?
    raise "usage: gopeed-dl add <url> [--name FILE] [--dir DIR]"
  end
  name = nil
  dir = nil
  i = 0
  while i < rest.length
    case rest[i]
    when "--name"
      i += 1
      name = rest[i]
    when "--dir"
      i += 1
      dir = rest[i]
    else
      raise "unknown option #{rest[i]}"
    end
    i += 1
  end
  opts = {}
  opts["name"] = name unless name.nil?
  opts["path"] = dir unless dir.nil?
  id = api("POST", "/api/v1/tasks", { "req" => { "url" => url }, "opts" => opts })
  puts "added task #{id}"
  puts "url: #{url}"
end

def cmd_list
  tasks = api("GET", "/api/v1/tasks")
  if tasks.nil? || tasks.empty?
    puts "no tasks"
    return
  end
  tasks.each do |t|
    puts "#{t["id"]}  #{t["status"]}  #{pct(t)}%  #{fmt_bytes(task_downloaded(t))}/#{fmt_bytes(task_size(t))}  #{t["name"]}"
  end
end

def cmd_status(id)
  print_task(api("GET", "/api/v1/tasks/" + check_id(id)))
end

def cmd_wait(id, timeout)
  id = check_id(id)
  deadline = Time.now + timeout
  loop do
    t = api("GET", "/api/v1/tasks/" + id)
    st = t["status"]
    puts "#{st}  #{pct(t)}%  #{fmt_bytes(task_downloaded(t))}/#{fmt_bytes(task_size(t))}  #{t["name"]}"
    if st == "done"
      opts = (t["meta"] || {})["opts"] || {}
      if opts["path"]
        puts "saved to: #{opts["path"]}/#{t["name"]}"
      end
      return
    end
    if st == "error"
      raise "task #{id} failed"
    end
    if Time.now >= deadline
      raise "timeout after #{timeout}s (task #{id} still #{st})"
    end
    sleep 1
  end
end

def cmd_pause(id)
  id = check_id(id)
  api("PUT", "/api/v1/tasks/#{id}/pause")
  puts "paused #{id}"
end

def cmd_continue(id)
  id = check_id(id)
  api("PUT", "/api/v1/tasks/#{id}/continue")
  puts "continued #{id}"
end

def cmd_remove(id, force)
  id = check_id(id)
  path = "/api/v1/tasks/" + id
  path += "?force=true" if force
  api("DELETE", path)
  puts "removed #{id}"
end

def usage
  puts "gopeed-dl: drive Gopeed (https://gopeed.com) over its REST API"
  puts "config: GOPEED_URL (http://127.0.0.1:9999, unix:///path/to/gopeed.sock, or unset = auto-detect), GOPEED_TOKEN (X-Api-Token, TCP only), GOPEED_SOCK (extra unix socket), GOPEED_APP (override; otherwise standard install paths + PATH are searched)"
  puts "usage:"
  puts "  gopeed-dl doctor                          # is a Gopeed app present? is the API up?"
  puts "  gopeed-dl start                           # launch GOPEED_APP and wait for the API"
  puts "  gopeed-dl ping"
  puts "  gopeed-dl add <url> [--name FILE] [--dir DIR]"
  puts "  gopeed-dl list"
  puts "  gopeed-dl status <id>"
  puts "  gopeed-dl wait <id> [--timeout SECONDS]"
  puts "  gopeed-dl pause <id> | continue <id>"
  puts "  gopeed-dl remove <id> [--force]"
end

def main
  cmd = ARGV[0]
  rest = []
  i = 1
  while i < ARGV.length
    rest << ARGV[i]
    i += 1
  end
  case cmd
  when nil, "help", "-h", "--help"
    usage
  when "doctor"
    cmd_doctor
  when "start"
    cmd_start
  when "ping"
    cmd_ping
  when "add"
    cmd_add(rest[0], rest[1..] || [])
  when "list"
    cmd_list
  when "status"
    cmd_status(rest[0])
  when "wait"
    timeout = 600
    rest.each_with_index do |a, idx|
      if a == "--timeout"
        if idx + 1 >= rest.length
          raise "bad --timeout value: (missing)"
        end
        v = rest[idx + 1]
        unless v =~ /\A\d+\z/
          raise "bad --timeout value: #{v}"
        end
        timeout = v.to_i
      end
    end
    cmd_wait(rest[0], timeout)
  when "pause"
    cmd_pause(rest[0])
  when "continue"
    cmd_continue(rest[0])
  when "remove"
    force = rest.include?("--force")
    cmd_remove(rest[0], force)
  else
    STDERR.puts "unknown command: #{cmd}"
    usage
    exit 2
  end
end

begin
  main
rescue => e
  STDERR.puts "gopeed-dl: #{e.message}"
  exit 1
end
