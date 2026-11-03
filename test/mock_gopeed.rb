# mock_gopeed.rb — a tiny in-memory stand-in for the Gopeed REST API,
# used to test gopeed-dl without a real Gopeed install.
#
#   ruby test/mock_gopeed.rb [port] [unix_sock_path]
#   MOCK_TOKEN=secret ruby test/mock_gopeed.rb   # require X-Api-Token
#
# With a second arg, the same API is also served on that UNIX socket
# (like the real desktop app in Protocol=Unix mode, no token needed there).
#
# Implements: GET /api/v1/info, POST /api/v1/tasks, GET /api/v1/tasks,
# GET /api/v1/tasks/{id}, PUT /api/v1/tasks/{id}/pause|continue,
# DELETE /api/v1/tasks/{id}. Tasks grow 2 MB per status poll and finish.

require "socket"
require "json"

PORT = (ARGV[0] || "19876").to_i
SOCK = ARGV[1]
TOKEN = ENV["MOCK_TOKEN"]
TASKS = {}
$seq = 0
$lock = Mutex.new

def ok(data)
  { "code" => 0, "msg" => "", "data" => data }
end

def err(msg, code = 1000)
  { "code" => code, "msg" => msg, "data" => nil }
end

def public_task(t)
  {
    "id" => t["id"], "protocol" => "http", "name" => t["name"],
    "meta" => { "opts" => t["opts"], "req" => t["req"], "res" => { "name" => t["name"], "size" => t["size"] } },
    "status" => t["status"], "progress" => t["progress"], "size" => t["size"],
    "createdAt" => t["created"], "updatedAt" => t["created"],
  }
end

def handle(method, path, query, headers, body)
  if TOKEN && headers["x-api-token"] != TOKEN
    return [401, err("unauthorized", 1001)]
  end
  case [method, path]
  when ["GET", "/api/v1/info"]
    [200, ok({ "version" => "1.7.0-mock", "runtime" => "go1.24", "os" => "darwin", "arch" => "x86_64", "inDocker" => false })]
  when ["POST", "/api/v1/tasks"]
    req = JSON.parse(body)
    url = (req["req"] || {})["url"]
    return [200, err("param invalid: rid or req", 1002)] if url.nil? || url.empty?
    opts = req["opts"] || {}
    $lock.synchronize do
      $seq += 1
      id = "task-#{$seq}"
      name = opts["name"] || url.split("/").last
      TASKS[id] = {
        "id" => id, "name" => name, "status" => "start", "size" => 10_000_000,
        "progress" => { "used" => 0, "speed" => 5_000_000, "downloaded" => 0 },
        "size" => 10_000_000,
        "opts" => opts, "req" => { "url" => url }, "created" => Time.now.to_s,
      }
      return [200, ok(id)]
    end
  when ["GET", "/api/v1/tasks"]
    $lock.synchronize { TASKS.each_value { |t| grow(t) } }
    [200, ok(TASKS.values.map { |t| public_task(t) })]
  else
    if path =~ %r{\A/api/v1/tasks/([^/]+)(/pause|/continue)?\z}
      id = $1
      action = $2
      $lock.synchronize do
        return [500, "internal gopeed panic"] if id == "boom" # plain-text 500, like rest.writeError
        t = TASKS[id]
        return [200, err("task not found", 1003)] if t.nil?
        case [method, action]
        when ["GET", nil]
          grow(t)
          [200, ok(public_task(t))]
        when ["PUT", "/pause"]
          t["status"] = "pause" if t["status"] == "start"
          [200, ok(nil)]
        when ["PUT", "/continue"]
          t["status"] = "start" if t["status"] == "pause"
          [200, ok(nil)]
        when ["DELETE", nil]
          TASKS.delete(id)
          [200, ok(nil)]
        else
          [200, err("unsupported", 1002)]
        end
      end
    else
      [404, err("not found", 1004)]
    end
  end
end

def grow(t)
  return if t["status"] != "start"
  used = t["progress"]["downloaded"] + 2_000_000
  if used >= t["size"]
    t["progress"]["downloaded"] = t["size"]
    t["status"] = "done"
  else
    t["progress"]["downloaded"] = used
  end
end

def serve_conn(s)
  line = s.gets
  return if line.nil?
  method, full_path, = line.split(" ")
  path, query = full_path.split("?", 2)
  headers = {}
  while (h = s.gets) && h != "\r\n"
    k, v = h.split(":", 2)
    headers[k.downcase] = v.strip if k && v
  end
  body = ""
  if (len = headers["content-length"])
    body = s.read(len.to_i) || ""
  end
  status, payload = handle(method, path, query, headers, body)
  if payload.is_a?(String) # raw body, e.g. a plain-text 500
    s.write "HTTP/1.1 #{status} X\r\nContent-Type: text/plain\r\nContent-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}"
  else
    json = JSON.generate(payload)
    s.write "HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\nContent-Length: #{json.bytesize}\r\nConnection: close\r\n\r\n#{json}"
  end
end

def serve(server)
  loop do
    s = server.accept
    Thread.new(s) do |c|
      begin
        serve_conn(c)
      rescue => e
        warn "mock error: #{e.message}"
      ensure
        c.close
      end
    end
  end
end

server = TCPServer.new("127.0.0.1", PORT)
puts "mock gopeed on 127.0.0.1:#{PORT}#{TOKEN ? " (token required)" : ""}"
Thread.new { serve(server) }

if SOCK
  File.unlink(SOCK) if File.exist?(SOCK)
  userver = UNIXServer.new(SOCK)
  puts "mock gopeed on unix://#{SOCK} (no token, like the desktop app)"
  serve(userver)
end

sleep
