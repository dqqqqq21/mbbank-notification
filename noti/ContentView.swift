import SwiftUI

struct ContentView: View {
    @State private var account: String = ""
    @State private var amount: String = ""
    @State private var date: Date = Date()
    @State private var time: Date = Date()
    @State private var note: String = ""
    @State private var sign: String = "+"
    @State private var setBalanceText: String = ""
    @State private var currentBalance: Int = 0
    @State private var showUpdateAlert = false
    @State private var remoteURL: String = ""

    var body: some View {
        ZStack {
            Image("Background")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()

            VStack {
                Text("Tạo Thông Báo")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .padding()

                // Thông tin truy cập từ xa qua Wi-Fi.
                VStack(spacing: 2) {
                    Text("Truy cập từ xa (cùng Wi-Fi):")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(remoteURL)
                        .font(.callout)
                        .fontWeight(.semibold)
                        .foregroundColor(.blue)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 4)

                Form {
                    Section(header: Text("Số Dư Ảo")) {
                        HStack {
                            Text("Số dư hiện tại")
                            Spacer()
                            Text("\(NumberFormat.grouped(currentBalance)) VND")
                                .fontWeight(.semibold)
                                .foregroundColor(.blue)
                        }
                        HStack {
                            TextField("Đặt lại số dư", text: $setBalanceText)
                                .keyboardType(.numberPad)
                            Button("Lưu") {
                                currentBalance = BalanceStore.shared.setBalance(NumberFormat.digits(setBalanceText))
                                setBalanceText = ""
                            }
                        }
                    }
                    Section(header: Text("Thông Tin")) {
                        Picker("Loại giao dịch", selection: $sign) {
                            Text("+ Cộng").tag("+")
                            Text("− Trừ").tag("-")
                        }
                        .pickerStyle(.segmented)
                        TextField("Số Tài Khoản", text: $account)
                        TextField("Số Tiền", text: $amount)
                            .keyboardType(.numberPad)
                        DatePicker("Ngày", selection: $date, displayedComponents: .date)
                        DatePicker("Thời Gian", selection: $time, displayedComponents: .hourAndMinute)
                        TextField("Nội Dung Chuyển Khoản", text: $note)
                    }
                }
                .background(Color.white.opacity(0.8))
                .cornerRadius(30)
                .padding(40)

                Button(action: {
                    // Ngày/giờ mặc định = hiện tại (DatePicker khởi tạo bằng Date()); user có thể chỉnh.
                    let f = DateFormatter()
                    f.dateFormat = "dd/MM/yy"
                    let dateStr = f.string(from: date)
                    f.dateFormat = "HH:mm"
                    let timeStr = f.string(from: time)
                    // Áp giao dịch vào số dư ảo + gửi thông báo, cập nhật số dư hiển thị.
                    currentBalance = NotificationManager.shared.sendTransaction(
                        account: account,
                        sign: sign,
                        amount: NumberFormat.digits(amount),
                        note: note,
                        date: dateStr,
                        time: timeStr
                    )
                }) {
                    Text("Gửi Thông Báo")
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .padding()

                Spacer()

                Text("MB Bank Fake By Weans(haininh.site)")
                    .font(.footnote)
                    .foregroundColor(.gray)
                    .italic()
                    .padding()
            }
            .onAppear {
                NotificationManager.shared.requestAuthorization()
                // Nạp số dư ảo đã lưu (giữ nguyên qua các lần mở app).
                currentBalance = BalanceStore.shared.balance
                // Hiển thị địa chỉ để mở trên trình duyệt thiết bị khác.
                if let ip = WebServer.localIPAddress() {
                    remoteURL = "http://\(ip):\(WebServer.port)"
                } else {
                    remoteURL = "Chưa kết nối Wi-Fi"
                }
            }
        }
        .onAppear {
                    showUpdateAlert = true
                }
        .alert(isPresented: $showUpdateAlert) {
            Alert(
                title: Text("MB Bank Fake."),
                message: Text("App By HHNiOS(haininh.site)"),
                dismissButton: .cancel(Text("Đóng"))
            )
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
