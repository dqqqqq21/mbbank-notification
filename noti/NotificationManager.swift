import Foundation
import UserNotifications

class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("Notification access granted.")
            } else if let error = error {
                print("Notification access denied: \(error.localizedDescription).")
            }
        }
        UNUserNotificationCenter.current().delegate = self
    }
    
    func scheduleNotification(account: String, amount: String, date: Date, time: Date, service: String, note: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yy"
        let dateString = formatter.string(from: date)
        
        formatter.dateFormat = "HH:mm"
        let timeString = formatter.string(from: time)
        
        let maskedAccount = maskAccountNumber(account)
        
        let content = UNMutableNotificationContent()
        content.title = "Thông báo biến động số dư"
        content.body = "TK \(maskedAccount)|GD: \(amount)VND \(dateString) \(timeString) |SD: \(service)VND|ND: \(note)"
        content.sound = .default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error adding notification: \(error.localizedDescription)")
            }
        }
    }
    
    // Gửi thông báo ngay lập tức từ web server (fields dạng chuỗi).
    // date/time là chuỗi tùy chọn; nếu nil hoặc rỗng thì lấy ngày/giờ hiện tại.
    func sendNow(account: String, amount: String, balance: String, note: String, date: String?, time: String?) {
        let formatter = DateFormatter()

        let dateString: String
        if let date = date, !date.trimmingCharacters(in: .whitespaces).isEmpty {
            dateString = date
        } else {
            formatter.dateFormat = "dd/MM/yy"
            dateString = formatter.string(from: Date())
        }

        let timeString: String
        if let time = time, !time.trimmingCharacters(in: .whitespaces).isEmpty {
            timeString = time
        } else {
            formatter.dateFormat = "HH:mm"
            timeString = formatter.string(from: Date())
        }

        let maskedAccount = maskAccountNumber(account)

        let content = UNMutableNotificationContent()
        content.title = "Thông báo biến động số dư"
        content.body = "TK \(maskedAccount)|GD: \(amount)VND \(dateString) \(timeString) |SD: \(balance)VND|ND: \(note)"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error adding notification: \(error.localizedDescription)")
            }
        }
    }

    // Gửi thông báo giao dịch dùng SỐ DƯ ẢO lưu bền.
    // sign: "+" cộng tiền, "-" trừ tiền (không cho số dư xuống dưới 0).
    // amount: số tiền (số nguyên VND). Tự cộng/trừ vào số dư ảo, lưu lại và hiển thị số dư mới.
    // date/time: chuỗi tùy chọn; nil hoặc rỗng -> lấy ngày/giờ hiện tại.
    // Trả về số dư mới sau giao dịch.
    @discardableResult
    func sendTransaction(account: String, sign: String, amount: Int, note: String, date: String?, time: String?) -> Int {
        // Chuẩn hóa dấu và cập nhật số dư ảo.
        let normalizedSign = (sign == "-" || sign.lowercased() == "minus" || sign.lowercased() == "tru") ? "-" : "+"
        let newBalance = BalanceStore.shared.apply(sign: normalizedSign, amount: amount)

        // Định dạng số có dấu phẩy ngăn cách hàng nghìn.
        let amountDisplay = "\(normalizedSign)\(NumberFormat.grouped(amount))"
        let balanceDisplay = NumberFormat.grouped(newBalance)

        let formatter = DateFormatter()

        let dateString: String
        if let date = date, !date.trimmingCharacters(in: .whitespaces).isEmpty {
            dateString = date
        } else {
            formatter.dateFormat = "dd/MM/yy"
            dateString = formatter.string(from: Date())
        }

        let timeString: String
        if let time = time, !time.trimmingCharacters(in: .whitespaces).isEmpty {
            timeString = time
        } else {
            formatter.dateFormat = "HH:mm"
            timeString = formatter.string(from: Date())
        }

        let maskedAccount = maskAccountNumber(account)

        let content = UNMutableNotificationContent()
        content.title = "Thông báo biến động số dư"
        content.body = "TK \(maskedAccount)|GD: \(amountDisplay)VND \(dateString) \(timeString) |SD: \(balanceDisplay)VND|ND: \(note)"
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error adding notification: \(error.localizedDescription)")
            }
        }

        return newBalance
    }

    // Handle notifications while app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.alert, .sound])
    }
    
    private func maskAccountNumber(_ account: String) -> String {
        guard account.count >= 5 else { return account }
        let start = account.prefix(2)
        let end = account.suffix(3)
        return "\(start)xxx\(end)"
    }
}

// MARK: - BalanceStore
// Kho lưu SỐ DƯ ẢO bền vững qua UserDefaults. Mở lại app vẫn giữ nguyên số dư.
final class BalanceStore {
    static let shared = BalanceStore()
    private let key = "virtualBalance"
    private init() {}

    // Số dư ảo hiện tại (VND, số nguyên không âm).
    var balance: Int {
        get { UserDefaults.standard.integer(forKey: key) }
        set { UserDefaults.standard.set(max(0, newValue), forKey: key) }
    }

    // Đặt số dư trực tiếp (không cho âm). Trả về số dư đã lưu.
    @discardableResult
    func setBalance(_ value: Int) -> Int {
        balance = max(0, value)
        return balance
    }

    // Áp dụng giao dịch. "+" cộng, "-" trừ nhưng không cho xuống dưới 0 (tối thiểu = 0).
    // Trả về số dư mới sau khi lưu.
    @discardableResult
    func apply(sign: String, amount: Int) -> Int {
        let current = balance
        let updated: Int
        if sign == "-" {
            updated = max(0, current - amount)   // trừ: kẹp sàn ở 0
        } else {
            updated = current + amount            // cộng
        }
        balance = updated
        return updated
    }
}

// MARK: - NumberFormat
// Tiện ích định dạng số: thêm dấu phẩy ngăn cách hàng nghìn, và trích số nguyên từ chuỗi.
enum NumberFormat {
    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.groupingSize = 3
        f.usesGroupingSeparator = true
        f.maximumFractionDigits = 0
        return f
    }()

    // 1000000 -> "1,000,000"
    static func grouped(_ value: Int) -> String {
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    // Trích chỉ chữ số từ chuỗi bất kỳ ("1,000,000" / "+1.000.000 VND" -> 1000000).
    static func digits(_ string: String) -> Int {
        let filtered = string.filter { $0.isNumber }
        return Int(filtered) ?? 0
    }
}
