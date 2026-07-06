import Foundation
import Network
import AVFoundation
import UIKit

// MARK: - WebServer
// Máy chủ HTTP/1.1 nhúng dùng Network framework, lắng nghe cổng 8080 trên mọi giao diện mạng.
// Cho phép laptop / thiết bị khác trong cùng Wi-Fi mở http://<ip-iphone>:8080 để gửi thông báo.
final class WebServer {
    static let shared = WebServer()

    // Cổng lắng nghe cố định 8080 (UI hiển thị cho người dùng).
    static let port: UInt16 = 8080

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "WebServer.listener")
    private var isRunning = false

    private init() {}

    // Khởi động máy chủ. Idempotent: gọi nhiều lần cũng chỉ chạy một lần.
    func start() {
        guard !isRunning else { return }

        do {
            // TCP thuần trên mọi giao diện (0.0.0.0 + ::) ở cổng 8080.
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let nwPort = NWEndpoint.Port(rawValue: WebServer.port) else {
                print("[WebServer] Cổng không hợp lệ.")
                return
            }
            let listener = try NWListener(using: params, on: nwPort)

            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    print("[WebServer] Đang lắng nghe trên cổng \(WebServer.port).")
                case .failed(let error):
                    print("[WebServer] Lỗi listener: \(error.localizedDescription)")
                    self?.isRunning = false
                case .cancelled:
                    print("[WebServer] Listener đã dừng.")
                    self?.isRunning = false
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleNewConnection(connection)
            }

            self.listener = listener
            listener.start(queue: queue)
            isRunning = true
        } catch {
            print("[WebServer] Không thể khởi động: \(error.localizedDescription)")
            isRunning = false
        }
    }

    // Đảm bảo listener còn sống; nếu đã chết thì dựng lại. Gọi khi quay lại foreground.
    func ensureRunning() {
        if listener == nil || !isRunning {
            listener?.cancel()
            listener = nil
            isRunning = false
            start()
        }
    }

    // MARK: - Xử lý kết nối

    private func handleNewConnection(_ connection: NWConnection) {
        // Mỗi kết nối chạy trên một hàng đợi nền riêng.
        let connQueue = DispatchQueue(label: "WebServer.conn.\(UUID().uuidString)")
        connection.start(queue: connQueue)
        receiveRequest(on: connection, buffer: Data())
    }

    // Đọc dữ liệu tới khi đủ header (\r\n\r\n) và đủ body theo Content-Length.
    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            var accumulated = buffer
            if let data = data, !data.isEmpty {
                accumulated.append(data)
            }

            if let error = error {
                print("[WebServer] Lỗi nhận dữ liệu: \(error.localizedDescription)")
                connection.cancel()
                return
            }

            // Tìm điểm kết thúc header.
            let headerTerminator = Data("\r\n\r\n".utf8)
            guard let headerRange = accumulated.range(of: headerTerminator) else {
                // Chưa đủ header.
                if isComplete {
                    self.sendResponse(on: connection, statusCode: 400, statusText: "Bad Request",
                                      contentType: "text/plain; charset=utf-8", body: Data("Bad Request".utf8))
                } else {
                    self.receiveRequest(on: connection, buffer: accumulated)
                }
                return
            }

            let headerData = accumulated.subdata(in: accumulated.startIndex..<headerRange.lowerBound)
            let bodyStart = headerRange.upperBound
            let currentBody = accumulated.subdata(in: bodyStart..<accumulated.endIndex)

            // Phân tích Content-Length (nếu có).
            let headerString = String(data: headerData, encoding: .utf8) ?? ""
            let contentLength = self.contentLength(from: headerString)

            if currentBody.count < contentLength && !isComplete {
                // Cần nhận thêm body.
                self.receiveRequest(on: connection, buffer: accumulated)
                return
            }

            // Đã đủ dữ liệu -> xử lý.
            let bodyData = contentLength > 0 ? currentBody.prefix(contentLength) : currentBody
            self.processRequest(headerString: headerString, body: Data(bodyData), on: connection)
        }
    }

    private func contentLength(from headers: String) -> Int {
        for line in headers.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }

    // MARK: - Định tuyến

    private func processRequest(headerString: String, body: Data, on connection: NWConnection) {
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse(on: connection, statusCode: 400, statusText: "Bad Request",
                         contentType: "text/plain; charset=utf-8", body: Data("Bad Request".utf8))
            return
        }

        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else {
            sendResponse(on: connection, statusCode: 400, statusText: "Bad Request",
                         contentType: "text/plain; charset=utf-8", body: Data("Bad Request".utf8))
            return
        }

        let method = String(requestParts[0]).uppercased()
        let fullPath = String(requestParts[1])

        // Tách path và query string.
        let pathAndQuery = fullPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(pathAndQuery[0])
        let queryString = pathAndQuery.count > 1 ? String(pathAndQuery[1]) : ""

        // Header Content-Type (để phân biệt JSON / form).
        let contentType = headerValue(named: "content-type", in: lines)?.lowercased() ?? ""

        // Trích các trường từ query (GET) hoặc body (POST form/JSON).
        let fields = requestFields(method: method, queryString: queryString, body: body, contentType: contentType)

        // Preflight CORS.
        if method == "OPTIONS" {
            sendResponse(on: connection, statusCode: 204, statusText: "No Content",
                         contentType: nil, body: Data(), extraHeaders: corsHeaders())
            return
        }

        switch (method, path) {
        case ("GET", "/"), ("GET", "/index.html"):
            let html = Data(WebServer.htmlPage.utf8)
            sendResponse(on: connection, statusCode: 200, statusText: "OK",
                         contentType: "text/html; charset=utf-8", body: html)

        case ("GET", "/favicon.ico"):
            sendResponse(on: connection, statusCode: 204, statusText: "No Content",
                         contentType: nil, body: Data())

        case ("GET", "/state"):
            // Trả về số dư ảo hiện tại để web hiển thị khi mở lên.
            sendResponse(on: connection, statusCode: 200, statusText: "OK",
                         contentType: "application/json; charset=utf-8", body: stateJSON(),
                         extraHeaders: corsHeaders())

        case ("GET", "/setBalance"), ("POST", "/setBalance"):
            // Đặt số dư ảo trực tiếp từ web (lưu bền).
            let value = NumberFormat.digits(fields["balance"] ?? "")
            BalanceStore.shared.setBalance(value)
            sendResponse(on: connection, statusCode: 200, statusText: "OK",
                         contentType: "application/json; charset=utf-8", body: stateJSON(),
                         extraHeaders: corsHeaders())

        case ("GET", "/notify"), ("POST", "/notify"):
            let account = fields["account"] ?? ""
            let amount = NumberFormat.digits(fields["amount"] ?? "")   // chỉ lấy chữ số
            let sign = fields["sign"] ?? fields["type"] ?? "+"          // "+" hoặc "-"
            let note = fields["note"] ?? ""
            let date = fields["date"]
            let time = fields["time"]

            // Áp giao dịch vào số dư ảo + gửi thông báo, lấy số dư mới cho phản hồi.
            let newBalance = NotificationManager.shared.sendTransaction(
                account: account, sign: sign, amount: amount,
                note: note, date: date, time: time)

            let json = Data("{\"ok\":true,\"balance\":\(newBalance),\"balanceFormatted\":\"\(NumberFormat.grouped(newBalance))\"}".utf8)
            sendResponse(on: connection, statusCode: 200, statusText: "OK",
                         contentType: "application/json; charset=utf-8", body: json,
                         extraHeaders: corsHeaders())

        default:
            let body = Data("Not Found".utf8)
            sendResponse(on: connection, statusCode: 404, statusText: "Not Found",
                         contentType: "text/plain; charset=utf-8", body: body)
        }
    }

    // Gộp việc trích trường từ GET (query) và POST (body form/JSON).
    private func requestFields(method: String, queryString: String, body: Data, contentType: String) -> [String: String] {
        if method == "GET" {
            return parseFormURLEncoded(queryString)
        }
        let bodyString = String(data: body, encoding: .utf8) ?? ""
        if contentType.contains("application/json") {
            return parseJSON(bodyString)
        }
        return parseFormURLEncoded(bodyString)
    }

    // JSON mô tả số dư ảo hiện tại.
    private func stateJSON() -> Data {
        let b = BalanceStore.shared.balance
        let f = NumberFormat.grouped(b)
        return Data("{\"balance\":\(b),\"balanceFormatted\":\"\(f)\"}".utf8)
    }

    private func headerValue(named name: String, in lines: [String]) -> String? {
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == name.lowercased() {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func corsHeaders() -> [String: String] {
        return [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type"
        ]
    }

    // MARK: - Ghi phản hồi HTTP

    private func sendResponse(on connection: NWConnection, statusCode: Int, statusText: String,
                             contentType: String?, body: Data, extraHeaders: [String: String] = [:]) {
        var response = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        if let contentType = contentType {
            response += "Content-Type: \(contentType)\r\n"
        }
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n"
        for (key, value) in extraHeaders {
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n"

        var data = Data(response.utf8)
        data.append(body)

        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Phân tích dữ liệu

    // Giải mã form-urlencoded: key=value&key2=value2, xử lý '+' và %XX.
    private func parseFormURLEncoded(_ string: String) -> [String: String] {
        var result: [String: String] = [:]
        guard !string.isEmpty else { return result }
        for pair in string.components(separatedBy: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawKey = kv.first else { continue }
            let key = urlDecode(String(rawKey))
            let value = kv.count > 1 ? urlDecode(String(kv[1])) : ""
            if !key.isEmpty {
                result[key] = value
            }
        }
        return result
    }

    // Giải mã percent-encoding, đổi '+' thành khoảng trắng.
    private func urlDecode(_ string: String) -> String {
        let replaced = string.replacingOccurrences(of: "+", with: " ")
        return replaced.removingPercentEncoding ?? replaced
    }

    // Phân tích JSON phẳng (chuỗi -> chuỗi). Đơn giản, chỉ lấy các cặp key/value cấp một.
    private func parseJSON(_ string: String) -> [String: String] {
        guard let data = string.data(using: .utf8) else { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = obj as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in dict {
            if let s = value as? String {
                result[key] = s
            } else if let n = value as? NSNumber {
                result[key] = n.stringValue
            }
        }
        return result
    }

    // MARK: - Địa chỉ IP LAN

    // Lấy địa chỉ IPv4 của Wi-Fi (ưu tiên en0). Trả về dạng dotted-quad.
    static func localIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var fallback: String?

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            let interface = current.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            // Chỉ lấy IPv4.
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(interface.ifa_addr,
                               socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: hostname)
                    if name == "en0" {
                        // Ưu tiên tuyệt đối en0 (Wi-Fi).
                        address = ip
                    } else if !name.hasPrefix("lo") && fallback == nil {
                        fallback = ip
                    }
                }
            }
            ptr = interface.ifa_next
        }

        return address ?? fallback
    }

    // MARK: - HTML control panel

    static let htmlPage: String = """
    <!DOCTYPE html>
    <html lang="vi">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>MB Bank Fake — Remote</title>
    <style>
      * { box-sizing: border-box; }
      body {
        margin: 0;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
        background: linear-gradient(160deg, #0a2a66 0%, #1e50a2 100%);
        min-height: 100vh;
        display: flex;
        align-items: center;
        justify-content: center;
        padding: 20px;
        color: #1a1a1a;
      }
      .card {
        background: #ffffff;
        border-radius: 20px;
        box-shadow: 0 12px 40px rgba(0,0,0,0.25);
        width: 100%;
        max-width: 440px;
        padding: 28px 24px 32px;
      }
      h1 {
        margin: 0 0 4px;
        font-size: 22px;
        color: #0a2a66;
        text-align: center;
      }
      .sub {
        margin: 0 0 22px;
        font-size: 13px;
        color: #6b7280;
        text-align: center;
      }
      label {
        display: block;
        font-size: 13px;
        font-weight: 600;
        color: #374151;
        margin: 14px 0 6px;
      }
      input {
        width: 100%;
        padding: 12px 14px;
        font-size: 15px;
        border: 1px solid #d1d5db;
        border-radius: 12px;
        outline: none;
        transition: border-color .15s;
      }
      input:focus { border-color: #1e50a2; }
      .row { display: flex; gap: 12px; }
      .row > div { flex: 1; }
      button {
        margin-top: 24px;
        width: 100%;
        padding: 14px;
        font-size: 16px;
        font-weight: 700;
        color: #fff;
        background: linear-gradient(135deg, #1e50a2, #0a2a66);
        border: none;
        border-radius: 12px;
        cursor: pointer;
      }
      button:active { opacity: .85; }
      .balance-box {
        background: linear-gradient(135deg, #0a2a66, #1e50a2);
        color: #fff;
        border-radius: 16px;
        padding: 16px 18px;
        margin-bottom: 8px;
        text-align: center;
      }
      .balance-label { font-size: 12px; opacity: .85; }
      .balance-value { font-size: 26px; font-weight: 800; margin-top: 4px; letter-spacing: .5px; }
      .btn-secondary {
        margin-top: 0;
        height: 100%;
        background: #e5edf9;
        color: #0a2a66;
      }
      .seg { display: flex; gap: 8px; margin-top: 6px; }
      .seg-btn {
        flex: 1;
        margin-top: 0;
        padding: 11px;
        font-size: 14px;
        font-weight: 700;
        background: #eef2f7;
        color: #374151;
        border: 2px solid transparent;
      }
      .seg-btn.active[data-sign="+"] { background: #dcfce7; color: #15803d; border-color: #16a34a; }
      .seg-btn.active[data-sign="-"] { background: #fee2e2; color: #b91c1c; border-color: #dc2626; }
      .toast {
        position: fixed;
        left: 50%;
        bottom: 30px;
        transform: translateX(-50%) translateY(20px);
        background: #111827;
        color: #fff;
        padding: 12px 22px;
        border-radius: 999px;
        font-size: 14px;
        opacity: 0;
        pointer-events: none;
        transition: opacity .25s, transform .25s;
      }
      .toast.show { opacity: 1; transform: translateX(-50%) translateY(0); }
      .toast.ok { background: #16a34a; }
      .toast.err { background: #dc2626; }
    </style>
    </head>
    <body>
      <div class="card">
        <h1>MB Bank Fake — Remote</h1>
        <p class="sub">Tạo thông báo biến động số dư từ xa</p>

        <div class="balance-box">
          <div class="balance-label">Số dư ảo hiện tại</div>
          <div class="balance-value" id="balanceValue">—</div>
        </div>

        <label for="setBalance">Đặt lại số dư</label>
        <div class="row">
          <div style="flex:2">
            <input id="setBalance" type="text" inputmode="numeric" placeholder="10,000,000">
          </div>
          <div style="flex:1">
            <button type="button" id="setBtn" class="btn-secondary">Lưu</button>
          </div>
        </div>

        <form id="f">
          <label>Loại giao dịch</label>
          <div class="seg">
            <button type="button" class="seg-btn active" data-sign="+">+ Cộng tiền</button>
            <button type="button" class="seg-btn" data-sign="-">− Trừ tiền</button>
          </div>

          <label for="account">Số Tài Khoản</label>
          <input id="account" name="account" type="text" inputmode="numeric" placeholder="0123456789">

          <label for="amount">Số Tiền</label>
          <input id="amount" name="amount" type="text" inputmode="numeric" placeholder="1,000,000">

          <label for="note">Nội Dung</label>
          <input id="note" name="note" type="text" placeholder="Chuyen tien">

          <div class="row">
            <div>
              <label for="date">Ngày (tùy chọn)</label>
              <input id="date" name="date" type="text" placeholder="dd/MM/yy">
            </div>
            <div>
              <label for="time">Giờ (tùy chọn)</label>
              <input id="time" name="time" type="text" placeholder="HH:mm">
            </div>
          </div>

          <button type="submit">Gửi Thông Báo</button>
        </form>
      </div>
      <div id="toast" class="toast"></div>
      <script>
        var toast = document.getElementById('toast');
        var balanceValue = document.getElementById('balanceValue');
        var sign = '+';

        function showToast(msg, ok) {
          toast.textContent = msg;
          toast.className = 'toast show ' + (ok ? 'ok' : 'err');
          setTimeout(function(){ toast.className = 'toast'; }, 2500);
        }

        // Chỉ giữ chữ số.
        function onlyDigits(v) { return (v + '').replace(/[^0-9]/g, ''); }
        // Thêm dấu phẩy ngăn cách hàng nghìn.
        function fmt(v) {
          v = onlyDigits(v);
          if (!v) return '';
          return v.replace(/\\B(?=(\\d{3})+(?!\\d))/g, ',');
        }
        function setBalanceText(formatted) {
          balanceValue.textContent = (formatted || '0') + ' VND';
        }

        // Tải số dư ảo hiện tại khi mở trang.
        function loadState() {
          fetch('/state').then(function(r){ return r.json(); })
            .then(function(d){ setBalanceText(d.balanceFormatted); })
            .catch(function(){});
        }
        loadState();

        // Tự thêm dấu phẩy khi gõ ở ô số tiền và ô đặt số dư.
        ['amount', 'setBalance'].forEach(function(id){
          var el = document.getElementById(id);
          el.addEventListener('input', function(){ el.value = fmt(el.value); });
        });

        // Nút chọn loại giao dịch (+/-).
        var segBtns = document.querySelectorAll('.seg-btn');
        segBtns.forEach(function(b){
          b.addEventListener('click', function(){
            segBtns.forEach(function(x){ x.classList.remove('active'); });
            b.classList.add('active');
            sign = b.getAttribute('data-sign');
          });
        });

        // Đặt lại số dư ảo.
        document.getElementById('setBtn').addEventListener('click', function(){
          var v = onlyDigits(document.getElementById('setBalance').value);
          fetch('/setBalance', {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: new URLSearchParams({ balance: v })
          })
          .then(function(r){ return r.json(); })
          .then(function(d){ setBalanceText(d.balanceFormatted); showToast('Đã cập nhật số dư', true); })
          .catch(function(){ showToast('Không kết nối được', false); });
        });

        // Gửi thông báo giao dịch.
        document.getElementById('f').addEventListener('submit', function(e){
          e.preventDefault();
          var params = new URLSearchParams();
          params.set('account', document.getElementById('account').value);
          params.set('amount', onlyDigits(document.getElementById('amount').value));
          params.set('sign', sign);
          params.set('note', document.getElementById('note').value);
          params.set('date', document.getElementById('date').value);
          params.set('time', document.getElementById('time').value);
          fetch('/notify', {
            method: 'POST',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: params
          })
          .then(function(r){ return r.json(); })
          .then(function(d){
            if (d.ok) { setBalanceText(d.balanceFormatted); showToast('Đã gửi! SD: ' + d.balanceFormatted + ' VND', true); }
            else { showToast('Gửi thất bại', false); }
          })
          .catch(function(){ showToast('Không kết nối được', false); });
        });
      </script>
    </body>
    </html>
    """
}

// MARK: - BackgroundKeeper
// Phát âm thanh im lặng lặp vô hạn để giữ app (và NWListener) sống khi chạy nền.
// Mẹo này giúp các app sideload duy trì hoạt động ở chế độ nền.
final class BackgroundKeeper: NSObject, AVAudioPlayerDelegate {
    static let shared = BackgroundKeeper()

    private var player: AVAudioPlayer?
    private var watchdog: Timer?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var observing = false

    private override init() { super.init() }

    func start() {
        configureSession()
        startPlayer()
        registerObservers()
        startWatchdog()
    }

    // MARK: - Phiên âm thanh

    private func configureSession() {
        do {
            // .playback (KHÔNG mixWithOthers): app trở thành audio chính -> iOS cho chạy nền
            // ổn định. Đánh đổi: tạm dừng nhạc/khác đang phát trên máy.
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [])
            try session.setActive(true, options: [])
        } catch {
            print("[BackgroundKeeper] Lỗi session: \(error.localizedDescription)")
        }
    }

    private func startPlayer() {
        do {
            if player == nil {
                // Audio biên độ cực nhỏ (gần như im lặng nhưng vẫn là "audio thật")
                // để iOS coi là đang phát và giữ app sống ở nền.
                let wavData = BackgroundKeeper.makeKeepAliveWAV(seconds: 30.0)
                let p = try AVAudioPlayer(data: wavData)
                p.numberOfLoops = -1 // lặp vô hạn
                p.volume = 0.01
                p.delegate = self
                p.prepareToPlay()
                player = p
            }
            if player?.isPlaying != true {
                player?.play()
            }
        } catch {
            print("[BackgroundKeeper] Lỗi player: \(error.localizedDescription)")
        }
    }

    // Kiểm tra định kỳ: nếu audio bị dừng thì kích hoạt lại + phát tiếp.
    private func startWatchdog() {
        watchdog?.invalidate()
        let t = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.ensurePlaying()
        }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    private func ensurePlaying() {
        if player?.isPlaying != true {
            configureSession()
            startPlayer()
        }
    }

    // MARK: - Theo dõi sự kiện làm gián đoạn audio

    private func registerObservers() {
        guard !observing else { return }
        observing = true
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleInterruption(_:)),
                       name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleRouteChange(_:)),
                       name: AVAudioSession.routeChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleForeground),
                       name: UIApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleBackground),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    // Sau khi bị ngắt (cuộc gọi, app khác chiếm audio) kết thúc -> phát lại.
    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .ended {
            configureSession()
            startPlayer()
        }
    }

    // Đổi route (cắm/rút tai nghe, Bluetooth) -> đảm bảo còn phát.
    @objc private func handleRouteChange(_ note: Notification) {
        ensurePlaying()
    }

    @objc private func handleForeground() {
        endBackgroundTask()
        ensurePlaying()
        WebServer.shared.ensureRunning() // dựng lại listener nếu đã chết
    }

    @objc private func handleBackground() {
        // Xin thêm thời gian nền và đảm bảo audio đang phát khi chuyển sang app khác.
        beginBackgroundTaskIfNeeded()
        configureSession()
        startPlayer()
    }

    private func beginBackgroundTaskIfNeeded() {
        guard bgTask == .invalid else { return }
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "WebServerKeepAlive") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        startPlayer() // phòng khi vòng lặp kết thúc bất thường
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        ensurePlaying()
    }

    // MARK: - Tạo WAV giữ nền (16-bit PCM, biên độ cực nhỏ, tần số thấp -> gần như không nghe được)

    private static func makeKeepAliveWAV(seconds: Double) -> Data {
        let sampleRate: Int = 8000
        let channels: Int = 1
        let bitsPerSample: Int = 16
        let frameCount = Int(Double(sampleRate) * seconds)
        let bytesPerSample = bitsPerSample / 8
        let dataSize = frameCount * channels * bytesPerSample
        let byteRate = sampleRate * channels * bytesPerSample
        let blockAlign = channels * bytesPerSample
        let chunkSize = 36 + dataSize

        var data = Data()

        func appendString(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func appendUInt32LE(_ v: UInt32) {
            data.append(UInt8(v & 0xff))
            data.append(UInt8((v >> 8) & 0xff))
            data.append(UInt8((v >> 16) & 0xff))
            data.append(UInt8((v >> 24) & 0xff))
        }
        func appendUInt16LE(_ v: UInt16) {
            data.append(UInt8(v & 0xff))
            data.append(UInt8((v >> 8) & 0xff))
        }
        func appendInt16LE(_ v: Int16) { appendUInt16LE(UInt16(bitPattern: v)) }

        // Header RIFF/WAVE (44 byte).
        appendString("RIFF")
        appendUInt32LE(UInt32(chunkSize))
        appendString("WAVE")
        appendString("fmt ")
        appendUInt32LE(16)
        appendUInt16LE(1)                        // PCM
        appendUInt16LE(UInt16(channels))
        appendUInt32LE(UInt32(sampleRate))
        appendUInt32LE(UInt32(byteRate))
        appendUInt16LE(UInt16(blockAlign))
        appendUInt16LE(UInt16(bitsPerSample))
        appendString("data")
        appendUInt32LE(UInt32(dataSize))

        // Sóng sin tần số rất thấp (~20Hz), biên độ ~16/32767 -> gần như không nghe thấy,
        // nhưng là tín hiệu audio thật để iOS không tạm dừng app ở chế độ nền.
        let amplitude: Double = 16.0
        let frequency: Double = 20.0
        let twoPiFOverSR = 2.0 * Double.pi * frequency / Double(sampleRate)
        for i in 0..<frameCount {
            let sample = Int16(amplitude * sin(twoPiFOverSR * Double(i)))
            appendInt16LE(sample)
        }

        return data
    }
}
