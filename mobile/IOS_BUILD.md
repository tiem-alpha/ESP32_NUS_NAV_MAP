# Build NavHUD trên iOS

Project iOS dùng deployment target iOS 13 và Flutter 3.44 trở lên. Flutter 3.44
dùng Swift Package Manager theo mặc định và tự fallback sang CocoaPods cho plugin
chưa hỗ trợ SwiftPM.

## Chuẩn bị máy Mac

1. Cài Flutter stable 3.44 trở lên và Xcode mới nhất.
2. Mở Xcode một lần để cài component và chấp nhận license.
3. Cài CocoaPods vì `flutter_foreground_task` hiện vẫn cần cơ chế fallback:

   ```bash
   brew install cocoapods
   ```

4. Kiểm tra môi trường:

   ```bash
   flutter doctor -v
   ```

## Build không cần tài khoản Apple

Từ thư mục `mobile`:

```bash
flutter clean
flutter pub get
flutter build ios --simulator
```

Build simulator được tạo tại `build/ios/iphonesimulator/Runner.app`.

## Chạy hoặc build trên iPhone thật

```bash
flutter pub get
open ios/Runner.xcworkspace
```

Trong Xcode, chọn **Runner > Signing & Capabilities**, chọn Apple Development
Team và đổi bundle identifier `com.map.navhud` nếu identifier này không thuộc
tài khoản của bạn. Sau đó có thể chạy từ Xcode hoặc dùng:

```bash
flutter run
flutter build ios --release
```

Việc chọn Development Team không được commit vì nó phụ thuộc tài khoản Apple
của từng máy. Các quyền Location, Bluetooth và Background Modes đã được cấu hình
trong project.

## Build kiểm tra không ký mã

```bash
flutter build ios --release --no-codesign
```

Lệnh này kiểm tra compile/archive nhưng không tạo bản có thể cài lên thiết bị.

## Cấu hình API khi build

Các endpoint và API key tùy chọn vẫn truyền bằng `--dart-define`, ví dụ:

```bash
flutter run \
  --dart-define=GOONG_API_KEY=your-key \
  --dart-define=VALHALLA_URL=https://your-valhalla-host
```
