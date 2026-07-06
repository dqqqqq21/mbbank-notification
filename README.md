# Fake MB Notification App

Đây là một dự án ứng dụng iOS giả lập thông báo của ngân hàng MB, được phát triển với mục đích học tập và thử nghiệm. Ứng dụng này cho phép bạn tạo các thông báo giả về giao dịch ngân hàng.

## Yêu cầu

- Xcode 12.5 trở lên
- Swift 5.3 trở lên
- macOS 11.0 trở lên
- Command line tools: `xcodebuild`, `codesign`, `ldid`

## Cài đặt

1. Clone repository này về máy tính của bạn:

    ```bash
    git clone https://github.com/WeansHHN/MB-Bank-Fake.git
    cd MB-Bank-Fake
    ```

2. Mở dự án bằng Xcode:

    ```bash
    open MB-Bank-Fake.xcodeproj
    ```

3. Thực hiện các thiết lập cần thiết trong Xcode nếu cần, chẳng hạn như thay đổi team ID hoặc điều chỉnh các cài đặt liên quan đến signing.

## Sử dụng

### Tạo bản build IPA hoặc TIPA

Chạy script `ipabuild.sh` để tạo file IPA hoặc TIPA.

1. Đảm bảo bạn có quyền thực thi trên file script:

    ```bash
    chmod +x ipabuild.sh
    ```

2. Chạy script:

    ```bash
    ./ipabuild.sh
    ```

   Nếu bạn muốn tạo bản debug, thêm tham số `--debug`:

    ```bash
    ./ipabuild.sh --debug
    ```

### Kết quả

File IPA hoặc TIPA sẽ được tạo trong thư mục gốc của dự án với tên `noti.tipa` hoặc `noti.ipa` tùy thuộc vào lựa chọn của bạn.

## Tính năng điều khiển từ xa (Web trong cùng mạng Wi‑Fi)

Khi mở app trên iPhone, ứng dụng tự động bật một **máy chủ web nhúng** lắng nghe trên
`0.0.0.0:8080` (mọi giao diện mạng). Thiết bị khác cùng Wi‑Fi (laptop, điện thoại...) chỉ cần
mở trình duyệt tới địa chỉ hiển thị trong app, ví dụ `http://192.168.1.10:8080`, là có thể tạo
thông báo gửi thẳng tới iPhone.

- **Chạy nền:** app dùng background mode `audio` + âm thanh im lặng để giữ máy chủ sống khi bạn
  chuyển sang app khác. Thiết bị khác vẫn gửi thông báo bình thường.
- **Quyền cần cấp trên iPhone:** Thông báo (Notifications) và Mạng cục bộ (Local Network).

### Số dư ảo (lưu bền)

- Số dư được lưu qua `UserDefaults`, **mở lại app vẫn giữ nguyên**.
- Khi tạo thông báo, chọn **+ (cộng)** hoặc **− (trừ)**; trừ **không cho số dư xuống dưới 0**
  (tối thiểu = 0). Mỗi giao dịch tự cộng/trừ vào số dư ảo rồi lưu lại.
- **Ngày/giờ mặc định là hiện tại**, chỉ đổi khi bạn tự nhập.
- **Số tiền và số dư tự thêm dấu phẩy** ngăn cách hàng nghìn (ví dụ `1,000,000`).

Các endpoint của máy chủ: `GET /` (trang điều khiển), `GET /state` (số dư hiện tại),
`POST /setBalance` (đặt số dư), `GET|POST /notify` (tạo thông báo).

## CI/CD (GitHub Actions)

`.github/workflows/build.yml` tự build file `.tipa` **chưa ký** trên runner macOS mỗi khi push
lên `main`, push tag `v*`, hoặc chạy thủ công (workflow_dispatch). File được tải lên artifact
`noti-tipa`; khi push tag sẽ tạo GitHub Release đính kèm file `.tipa`.

## Cấu trúc Dự án

- `ContentView.swift`: Giao diện người dùng và logic của ứng dụng (form tạo thông báo, số dư ảo).
- `NotificationManager.swift`: Tạo thông báo cục bộ; `BalanceStore` (số dư ảo) và `NumberFormat`.
- `WebServer.swift`: Máy chủ HTTP nhúng (`NWListener`), trang web điều khiển, và `BackgroundKeeper`.
- `ipabuild.sh`: Script xây dựng để tạo file IPA hoặc TIPA.
- `noti.entitlements`: File chứa các entitlements cần thiết cho ứng dụng.

## Ghi chú

Đây là một ứng dụng giả lập thông báo ngân hàng, không sử dụng cho mục đích lừa đảo hoặc gây hiểu lầm. Mục đích duy nhất của dự án này là học tập và thử nghiệm.

## Liên hệ

Nếu bạn có bất kỳ câu hỏi nào, vui lòng liên hệ:

- Website: https://haininh.site
- GitHub: [WeansHHN](https://github.com/WeansHHN)
