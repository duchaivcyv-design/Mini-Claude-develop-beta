# ClaudeMini 0.7.0 — Chat Gemini và Claude, sửa tin cũ, video, tạo ảnh và xuất Word/TXT

## Mới: Skin, chế độ tối, nền chat, đổi icon
Cài đặt › **Giao diện** (màn Lịch sử › Cài đặt › Giao diện). Đổi xong áp dụng ngay, cuộc trò chuyện đang mở được giữ nguyên.
- **7 skin**: Claude (mặc định, giữ nguyên giao diện cũ) và 6 skin màu: **SideStore Skin** (tím), **LiveContainer Skin** (xanh biển), **Dopamine Skin** (xanh lá), **Chimera Skin** (trắng), **Sileo Skin** (xanh lam), **Github Skin** (đỏ). Mỗi skin có màu chủ đạo, ảnh nền chat và icon riêng.
- **Sáng / Tối / Tự động** (như màn Hiển thị của iOS): hai ảnh xem trước theo đúng skin đang chọn; bật **Tự động** thì app tối từ 18:00 đến 06:00 theo giờ trên máy. Hộp thoại hệ thống chỉ tối theo trên iOS 13 trở lên.
- **Cài đặt** chia lại: *Cho app hợp gu bạn* (giao diện, ngôn ngữ) › *Chìa khóa kết nối AI* › *Cách AI trò chuyện với bạn* › *Dữ liệu & thông tin*.
- **Nền chat**: Theo skin / Không dùng ảnh nền / chọn bất kỳ trong 6 ảnh nền. Khi có ảnh nền, tin nhắn của AI nằm trong thẻ mờ để luôn dễ đọc; chế độ tối làm tối ảnh nền.
- **Icon ứng dụng**: chọn icon của từng skin hoặc quay về icon mặc định (dùng `setAlternateIconName`, iOS sẽ hiện thông báo xác nhận). Khi chọn một skin, app hỏi có đổi luôn icon không.
- Cách làm: `src/Theme.m` (bảng màu sáng/tối của từng skin), `src/AppearanceViewController.m` (màn hình chọn), `app/Resources/web/chat.css` (dùng biến màu `--bg`, `--accent`…; app chèn bảng màu của skin vào `<style id="themevars">`), `app/Resources/Wallpapers/` (6 ảnh nền JPEG), `app/Resources/Icon-*@2x/@3x.png` + `CFBundleAlternateIcons` trong `app/Info.plist` (6 icon).
- Số phiên bản (`VERSION`) và mức iOS tối thiểu (12.0) **không đổi**. Gói `.deb` vẫn là rootful (`iphoneos-arm`, cài vào `/Applications`).

App chat Gemini và Claude cho iPhone iOS 12 đã jailbreak (arm64), giao diện kiểu Claude (sáng, tiếng Việt/Anh theo ngôn ngữ máy).

## Bản này làm được gì
- **Nhập API key của chính bạn** ở lần mở đầu, có nút kiểm tra. Key chỉ nằm trên máy (Keychain, hoặc file quyền 0600 nếu Keychain từ chối). Không có key nào trong code hay trong .deb.
- **Chat nhiều lượt, chữ chạy dần**, nút **dừng** trong lúc đang trả lời, nút **Sao chép / Lưu** dưới câu trả lời. Tin nhắn cũ của bạn có nút **Sao chép / Sửa**; sửa một tin sẽ bỏ các tin phía sau để gửi lại từ vị trí đó.
- **Chọn model**: chạm vào tên model ở giữa thanh trên cùng. Danh sách lấy trực tiếp từ API của từng nhà cung cấp theo key của bạn (không ghi cứng tên model). Mặc định chọn bản Flash ổn định mới nhất.
- **Lịch sử** (nút ba gạch bên trái): lưu trên máy, có **tìm kiếm** (theo tiêu đề và nội dung), **vuốt trái để Đổi tên / Xóa**.
- **Cài đặt** (trong màn Lịch sử): đổi key, đặt chỉ dẫn AI tối đa 100.000 ký tự, giới hạn token đầu ra và độ dài lịch sử gửi cho model, xóa toàn bộ lịch sử, xem phiên bản.
- Nút **soạn mới** (hình ô vuông có bút) bên phải: cuộc trò chuyện mới.

## Thay đổi ở 0.2.1
- **Sửa lỗi chat bị đứng ở dấu chấm chờ.** Nếu kết nối chạy dần (stream) bị lỗi mạng trước khi nhận được chữ nào, app tự gửi lại một lần dưới dạng yêu cầu thường (nhận cả câu trả lời một lúc). Kết nối stream cũng không còn nén dữ liệu để các đoạn chữ không bị giữ lại.
- **Báo lỗi mạng cụ thể.** Thẻ lỗi giờ có dòng "Chi tiết" ghi lý do thật (ví dụ hết thời gian chờ, mất kết nối, lỗi TLS) kèm mã lỗi, thay vì chỉ một câu chung chung.

## Mới ở 0.7.0: sửa tin cũ, tăng giới hạn, video, tạo ảnh và xuất tệp
ClaudeMini - requested targeted changes

Replace only these files at the same paths in the repository:
- src/AppSettings.h
- src/AppSettings.m
- src/SettingsViewController.m
- src/GeminiStream.m
- src/ClaudeStream.m
- app/Resources/vi.lproj/Localizable.strings
- app/Resources/en.lproj/Localizable.strings

Changes:
- System instruction limit raised from 100,000 to 1,000,000 characters (stored locally and included in provider request; provider context limits still apply).
- Added persisted reasoning-level setting: Low, Medium, High, Very High, MAX.
- Gemini thinkingBudget is sent only to Gemini 2.5 models.
- Claude extended-thinking budget is sent only to Claude 3.7 and Claude Sonnet/Opus 4 model families, with output budget room reserved.
- Existing output token cap and conversation context settings remain unchanged.

Not implemented by these changes:
- @ Google app integrations: require OAuth, Google APIs and connector/backend implementation; a menu alone would not grant access.
- /tạo ảnh command alias: existing image-capable Gemini model path remains; slash-command routing is not added here.
- 50 million–1 billion tokens/day: this is not a client-side setting the app can grant. Actual quota is set by provider account/project and billing. This source version does not yet meter provider-reported daily token usage, so no fake quota switch was added.
- MAX ×8 is a UI level label; it cannot force a provider to use 8x compute or exceed model/API limits.

Validation: balanced delimiter sanity checks passed. Full iOS build not run; Xcode/iOS SDK is not available in this environment.

## Mới ở 0.6.0: file .ipa
Mỗi lần build, GitHub Actions tạo thêm một artifact thứ hai tên **ClaudeMini-ipa** chứa file IPA theo số phiên bản hiện tại (artifact `ClaudeMini-deb` vẫn có như cũ).
- **Dành cho máy đã jailbreak có AppSync Unified** (cài từ Sileo). File được ký giả bằng `ldid`, không có chữ ký của Apple, nên máy chưa jailbreak không cài được. Cài bằng Filza (chạm vào file `.ipa` rồi chọn Install) hoặc một công cụ cài IPA khác trên máy jailbreak. Để cài trên máy không jailbreak cần ký lại bằng chữ ký của chính bạn (ví dụ Sideloadly hoặc AltStore); mình chưa kiểm tra chúng có hỗ trợ iOS 12 hay không.
- **Khác với `.deb`:** bản `.ipa` chạy trong sandbox bình thường như app App Store (không dùng quyền đặc biệt `platform-application` và `no-container` của bản `.deb`). Lịch sử và API key nằm trong thư mục riêng của app. Bản `.deb` thì cài như ứng dụng hệ thống vào `/Applications`.
- **Đừng cài cả hai cùng lúc:** hai bản trùng bundle id `com.puc.claudemini`. Hãy gỡ bản này trước khi cài bản kia. Dữ liệu của hai bản không dùng chung.
- File tạo bằng `tools/make_ipa.sh`, quyền dùng nằm trong `app/entitlements-ipa.plist`.

## Mới ở 0.5.2
- **Câu chào theo giờ** ở màn hình chat trống, lấy giờ của thiết bị: **03:00–10:59** Chào buổi sáng, **11:00–13:59** Chào buổi trưa, **14:00–17:59** Chào buổi chiều, **18:00–22:59** Chào buổi tối, **23:00–02:59** Chào cú đêm. Có cả tiếng Anh. Mốc giờ nằm ở hàm `greetingTitle` trong `src/ChatViewController.m`.
- **Sáu câu hỏi thay đổi** dưới lời chào (câu cũ "Hôm nay bạn muốn học gì?" và 5 câu mới), chọn ngẫu nhiên mỗi lần mở app hoặc bấm cuộc trò chuyện mới, không lặp lại câu liền trước. Chữ nằm trong `Localizable.strings` (`greeting_*`, `empty_sub_1` đến `empty_sub_6`).
- Nếu bạn để app mở qua một mốc giờ khi chat còn trống, lời chào tự đổi khi quay lại app.

## Mới ở 0.5.1
- **Icon mới** (ngôi sao nhiều màu trên nền sáng). Ảnh được xóa watermark, đưa về hình vuông, xuất đủ kích thước cho iPhone, và dùng luôn cho logo trong app và ảnh khởi động.
- **Bạn không cần repo Sileo.** Bước `publish` tự bỏ qua khi bạn chưa cài `SILEO_TOKEN` và `SILEO_REPO`. Chỉ cần chạy **Build ClaudeMini** trong tab Actions rồi tải file `.deb` trong mục Artifacts (tên `ClaudeMini-deb`), sau đó chép vào máy và cài bằng Filza hoặc `dpkg -i`.

## Mới ở 0.5.0 (giai đoạn 4)

**4A. Nhật ký chẩn đoán.** Cài đặt › Nhật ký chẩn đoán. App ghi lại các sự kiện và mã lỗi (mở app, kiểm tra key, mỗi yêu cầu gửi đi và kết quả, nhập tệp, lỗi của trang chat, WebKit bị iOS tắt…) để bạn báo lỗi bằng sự thật thay vì đoán. Có nút **Sao chép** và **Xóa**. App không ghi API key, nội dung tin nhắn hay tên tệp; lời báo lỗi do Google/Anthropic trả về được giữ nguyên, nên hãy đọc qua trước khi gửi cho ai.

**4B. Tự đưa bản build vào repo Sileo.** Workflow có thêm bước `publish`, chỉ chạy khi bạn đã cài đặt (nếu chưa, nó bỏ qua và bản `.deb` vẫn có trong Artifacts):
1. Trên GitHub: Settings › Developer settings › Personal access tokens › **Fine-grained tokens** › Generate. Chọn **Only select repositories** và chỉ chọn repo Sileo của bạn. Mục Permissions đặt **Contents: Read and write**. Sao chép token.
2. Trong repo ClaudeMini: Settings › Secrets and variables › Actions. Tab **Secrets**: tạo `SILEO_TOKEN` (dán token). Tab **Variables**: tạo `SILEO_REPO` (ví dụ `tenban/repo-sileo`).
3. Tùy chọn (tab Variables): `SILEO_BRANCH` (nhánh, mặc định là nhánh chính của repo) và `SILEO_DEBS_DIR` (thư mục chứa file .deb, mặc định `debs`).
Sau mỗi lần build, `tools/publish_repo.py` chép `.deb` vào thư mục đó, thay **đúng một mục** của ClaudeMini trong `Packages` (các gói khác giữ nguyên từng byte), tạo lại `Packages.gz/.bz2/.xz`, cập nhật hash trong `Release` rồi commit. Giữ 3 phiên bản mới nhất của ClaudeMini, xóa bản cũ hơn.
- **Nếu repo của bạn có chữ ký** (có `InRelease` hoặc `Release.gpg`), công cụ **từ chối** chạy để không làm hỏng chữ ký.
- **Giả định bố cục:** tệp `Packages` và `Release` nằm ở thư mục gốc của repo. Nếu repo của bạn để ở chỗ khác, hãy cho mình biết.
- Lần đầu nên sao lưu repo (tải bản zip) để yên tâm.

**4C. Bớt gửi lại ảnh, PDF và khung hình video.** Cài đặt › Ảnh, PDF và video đã gửi: **1 tin gần nhất / 3 tin gần nhất (mặc định) / Tất cả**. AI chỉ nhìn thấy ảnh, khung hình video và PDF khi chúng được gửi lại trong từng yêu cầu, nên gửi ít hơn thì tiết kiệm hạn mức, nhưng AI không còn xem được nội dung media cũ hơn (nó thấy một ghi chú thay thế). Chữ trích từ Word, PowerPoint, văn bản luôn được giữ. Mình chưa làm cách tải tệp lên một lần (Files API) vì chưa chắc nó tiết kiệm được hạn mức và cần thử với key thật.

**4D. Chỉ dẫn riêng cho từng cuộc trò chuyện.** Chạm vào tên model ở giữa thanh trên cùng (màn hình giờ tên là **Model và chỉ dẫn**): dòng đầu tiên là chỉ dẫn riêng cho cuộc trò chuyện đang mở, thay cho chỉ dẫn chung trong Cài đặt. Để trống là dùng chỉ dẫn chung. Lưu cùng cuộc trò chuyện.

## Mới ở 0.4.0 (giai đoạn 3)

**Câu trả lời hiển thị đẹp.** Dấu `**` giờ thành chữ in đậm, và còn có: tiêu đề, danh sách, bảng (cuộn ngang được), trích dẫn, liên kết, khối code tô màu có nút **Sao chép** (Python, JavaScript, C/C++, Java, SQL, HTML, Bash, Pascal, LaTeX, MATLAB…) và **công thức toán** (`$...$`, `$$...$$`, `\(...\)`, `\[...\]`). Mã HTML trong câu trả lời không bao giờ được chạy, chỉ hiện thành chữ. Công thức chưa viết xong lúc chữ đang chạy hiện tạm dạng chữ, đóng xong mới hiện thành công thức. Chữ tiếng Việt có dấu nằm trong công thức dùng font dự phòng nên khoảng cách có thể lệch nhẹ.

**Thêm Claude (Anthropic).** Cài đặt có hai mục: **API key Gemini** và **API key Claude**; có thể dùng một hoặc cả hai. Lần đầu mở app có công tắc Gemini | Claude để chọn key nhập trước. Danh sách model lấy trực tiếp từ từng nhà cung cấp, và model nào thì app tự dùng đúng nhà cung cấp đó; bạn có thể đổi model giữa chừng, lịch sử được gửi lại theo đúng định dạng của nhà cung cấp mới.
- **Key Claude không có gói miễn phí.** Cần nạp credit trước tại console.anthropic.com (mục Plans & Billing). Gói Claude Pro/Max là sản phẩm riêng và không cấp quyền dùng API. Hết credit, app báo rõ.
- Mặc định: có key Gemini thì dùng Gemini Flash mới nhất; chỉ có key Claude thì dùng Claude Sonnet mới nhất. Model Haiku rẻ hơn Sonnet.
- Ảnh và PDF gửi được cho cả hai nhà cung cấp.

**Chỉ dẫn cho AI (system prompt).** Cài đặt › Chỉ dẫn cho AI: một ô tự nhập (tối đa 100.000 ký tự), được gửi kèm mọi tin nhắn, lưu tự động. Áp dụng cho toàn app.

**Đổi ngôn ngữ.** Cài đặt › Ngôn ngữ: Tự động / Tiếng Việt / English. Đổi xong app dựng lại màn hình bằng ngôn ngữ mới (cuộc trò chuyện đang mở bắt đầu lại từ đầu).

**Chạm vào ảnh trong cuộc trò chuyện** để xem toàn màn hình, véo hai ngón hoặc chạm đúp để phóng to, chạm một lần để đóng.

## Mới ở 0.3.0: gửi ảnh và tài liệu
Nút **+** bên trái ô nhập mở menu: **Chụp ảnh**, **Chọn ảnh từ thư viện**, **Chọn tệp**. Tệp chờ gửi hiện thành ảnh nhỏ/thẻ phía trên ô nhập (bấm × để bỏ). Bạn có thể gửi tệp kèm câu hỏi, hoặc chỉ gửi tệp.

| Loại | Cách xử lý |
|---|---|
| Ảnh (JPG, PNG, HEIC, GIF…) | Thu nhỏ còn tối đa 2048 px, nén JPEG rồi gửi cho Gemini hoặc Claude |
| PDF (tối đa 10 MB) | Gửi nguyên cho Gemini hoặc Claude, đọc được cả bản scan và hình trong PDF |
| Video MOV/MP4 (tối đa 100 MB, 120 giây) | Trích tối đa 6 khung hình đại diện, gửi như ảnh; không gửi âm thanh |
| Word `.docx`, PowerPoint `.pptx` (tối đa 15 MB) | App tự trích chữ trên máy rồi gửi dạng văn bản (không đọc được ảnh/biểu đồ bên trong) |
| Văn bản, mã nguồn (`.txt`, `.md`, `.csv`, `.json`, `.py`…) | Gửi dạng văn bản (tối đa 4 MB, cắt còn 200.000 ký tự) |
| `.doc`, `.xls/.xlsx`, `.ppt`, `.pages`, `.rtf`… | Chưa hỗ trợ: hãy xuất sang PDF rồi gửi |

Giới hạn: tối đa 6 tệp mỗi tin nhắn; tổng dữ liệu ảnh, PDF và khung hình video trong một tin nhắn tối đa 13 MB.
Lưu ý quan trọng: API không tự giữ các tệp media cũ giữa các lượt, nên ảnh, khung hình video và PDF đã gửi được **gửi lại ở mỗi lượt** trong cùng cuộc trò chuyện (trong giới hạn dung lượng; tệp cũ nhất sẽ bị bỏ trước). Với tài liệu dài, nên bắt đầu cuộc trò chuyện mới khi chuyển sang chủ đề khác để tiết kiệm hạn mức.
Tệp đính kèm lưu trên máy (cùng lịch sử) và bị xóa khi bạn xóa cuộc trò chuyện hoặc toàn bộ lịch sử. Lần đầu dùng camera, iOS sẽ hỏi quyền.

## Thay đổi ở 0.2.2
- **Màn chọn model chia hai nhóm.** "Khuyên dùng cho key miễn phí" (họ Flash và Flash-Lite, mới nhất lên đầu) và "Có thể cần trả phí hoặc bị giới hạn" (Pro, Argon và các loại khác). Đây chỉ là gợi ý theo tên họ model, vì Google không cho biết điều này qua API.
- **Model mặc định luôn ưu tiên họ Flash,** không bao giờ tự chọn model trả phí khi đã có Flash/Flash-Lite trong danh sách.
- Thông báo "vượt hạn mức" giờ gợi ý chọn model khác.

## Nên dùng model nào với key miễn phí
Theo các nguồn tháng 10/2026 (Google không còn công bố hạn mức từng model, xem số liệu thật trong trang rate-limit của Google AI Studio):
- Chính: `gemini-3.8-flash` (mặc định). Dự phòng: `gemini-3.6-flash`.
- Nhẹ và nhanh: `gemini-3.5-flash-lite`, `gemini-3.1-flash-lite`, hoặc dòng 2.5 (`gemini-2.5-flash`, `gemini-2.5-flash-lite`).
- Cần trả phí: Gemini 4 Argon và các bản Pro. Riêng `gemini-2.5-pro` các nguồn chưa thống nhất.
- Gói miễn phí: Google có thể dùng nội dung bạn gửi để cải thiện sản phẩm của họ.

## Chưa có
- Tải tệp lên một lần rồi tham chiếu (Files API) để khỏi gửi lại PDF/ảnh.
- Ký repo Sileo (bước tự lên repo từ chối repo có chữ ký).

## Cách build (không cần Mac)
1. Tải **toàn bộ thư mục này** lên repo GitHub (giữ thư mục ẩn `.github`).
2. Tab **Actions** → **Build ClaudeMini** → **Run workflow**.
3. Tải artifact `ClaudeMini-deb` (hoặc `ClaudeMini-ipa` nếu bạn muốn file .ipa), lấy file `com.puc.claudemini_0.7.0_iphoneos-arm.deb`.
4. Đưa vào repo Sileo của bạn (hoặc chép vào máy và cài bằng Filza). Số phiên bản lớn hơn bản trước nên Sileo sẽ coi là bản cập nhật.

## Những gì cần để ý khi chạy thử lần đầu
- **Khung chat dùng WebKit.** Nếu sau khoảng 12 giây khung chat không hiện, app sẽ báo "Không mở được khung chat" kèm chi tiết. Hãy chụp lại thông báo đó gửi cho người hỗ trợ.
- Nếu một model có trong danh sách nhưng bị báo "không dùng được với key của bạn", hãy chọn model khác (Google có thể giới hạn quyền dùng một số model).
- Key miễn phí của Google có hạn mức theo phút/ngày. Khi vượt, app báo rõ và bạn thử lại sau.

## Cấu trúc
- `app/Resources/web/` — trang chat. `vendor.js` và `vendor.css` là markdown-it, highlight.js và KaTeX (đã chuyển xuống ES2018 cho Safari 12, font toán nhúng sẵn), tạo bằng `tools/build_web.py` (chỉ chạy khi muốn cập nhật thư viện, không cần cho việc build app); `render.js` là bộ hiển thị markdown/toán; `chat.js` là trang chat
- `tools/publish_repo.py` — cập nhật repo Sileo (đã thử trên repo giả lập); `src/DiagnosticLog.m` — nhật ký chẩn đoán
- `src/ClaudeStream.m`, `src/ClaudeClient.m` — gọi API Claude; `src/GeminiStream.m` — gọi API Gemini; `src/KeyStore.m` — lưu key từng nhà cung cấp
- `src/OfficeText.c` — bộ trích chữ Word/PowerPoint viết bằng C thuần (đã thử trên tệp thật và dữ liệu hỏng); `src/AttachmentStore.m` — lưu và xử lý tệp đính kèm
- `src/` — mã Objective-C: `ChatViewController` (màn chính), `GeminiStream` (gọi API dạng stream), `GeminiClient` (kiểm tra key, lấy danh sách model), `ConversationStore` (lịch sử), `ModelStore`, `HistoryViewController`, `SettingsViewController`, `ModelPickerViewController`, `RootViewController` (màn nhập key)
- `app/Resources/web/` — trang chat (HTML/CSS/JS viết kiểu cũ ES5 cho Safari 12)
- `app/` — `Info.plist`, quyền, icon, ảnh khởi động, chuỗi dịch
- `deb/DEBIAN/` — thông tin gói, script `postinst`/`postrm` (chạy `uicache`)
- `tools/make_ipa.sh` — đóng gói file .ipa; `app/entitlements-ipa.plist` — quyền của bản .ipa
- `build.sh`, `.github/workflows/build.yml` — build và đóng gói
- `VERSION` — số phiên bản; tăng số này mỗi lần cập nhật

## Lưu ý
- Trường `Maintainer` trong `deb/DEBIAN/control` đang là giá trị tạm (`puc`). Hãy sửa theo ý bạn.
- Lịch sử chỉ lưu trên máy này. Khi chat, nội dung được gửi tới nhà cung cấp model đang chọn (Google Gemini hoặc Anthropic Claude) bằng API key của bạn.
