# Power Automate Flow 2 - Backup và Application Health Monitor

Tài liệu kiến trúc, triển khai, bàn giao và xử lý sự cố cho Flow 2 theo `MBC-SPEC-BACKUP-001 v0.2`, mục 5.6.

## 1. Trạng thái hiện tại

### Phần đã hoạt động

- Backup script đã upload được file lên SharePoint document library `Backup_Database_Devs`, folder `DB_Backups`.
- Flow 1 - `Backup Result Handler` đã hoạt động.
- Webhook của Flow 1 trả HTTP `202`.
- Flow 1 đã ghi được từng kết quả site vào SharePoint list `DB_Backup_Log`.
- Flow 1 đã xử lý được payload và các trạng thái cần thiết. Flow 1 không còn là vấn đề cần debug.
- Trong `DB_Backup_Log` đã từng có row thành công dùng để xác nhận Flow 1 ghi đúng schema, ví dụ:

  ```text
  Title: 20260805_0233
  Site: timesheet_misa
  Status: success
  Created: 05/08/2026 02:33
  ```

- Row ngày 05/08 chỉ là bằng chứng Flow 1 đã ghi log thành công. Tại ngày 07/08, row này đã nằm ngoài cửa sổ 26 giờ và không thể dùng để kỳ vọng `timesheet_misa` là `success`. Mọi test Flow 2 phải tạo hoặc dùng một row success mới còn nằm trong cửa sổ 26 giờ.

### Phần duy nhất còn phải hoàn thiện

Flow 2 chưa hoàn tất. Flow 2 hiện có hai trách nhiệm:

1. Xác nhận mỗi site có ít nhất một backup `success` trong 26 giờ gần nhất.
2. Kiểm tra khả năng hoạt động của application theo mức quan sát hiện có: readiness API, URL probe hoặc ghi nhận chưa có dữ liệu giám sát.

Trong lần test ban đầu khi row `timesheet_misa` vẫn còn trong cửa sổ 26 giờ, logic backup đã append sai cả hai site vào `MissingBackupSites`:

```json
[
  "timesheet_misa",
  "site_khong_ton_tai"
]
```

Với điều kiện `timesheet_misa` có một row success mới trong 26 giờ, kết quả backup đúng phải chỉ có:

```json
[
  "site_khong_ton_tai"
]
```

Phần gọi health API là kiến trúc mới, chưa có endpoint hoặc cấu hình tương ứng trong repository tại thời điểm cập nhật tài liệu này.

## 2. Mục tiêu của Flow 2

Flow 1 chỉ báo cáo những gì backup script đã gửi lên. Nếu VPS chết, timer bị disable, script không chạy, mất mạng hoặc webhook không được gọi thì Flow 1 sẽ im lặng.

Flow 2 chạy độc lập trong Power Automate và chủ động kiểm tra hai tín hiệu khác nhau:

- `Backup health`: tín hiệu lịch sử, kiểm tra row `success` trong `DB_Backup_Log` trong 26 giờ gần nhất.
- `Application health`: tín hiệu thời gian thực theo khả năng quan sát hiện có. Readiness API là mức tốt nhất nhưng không bắt buộc mọi app phải có ngay từ đầu.

Hai tín hiệu phải được giữ độc lập. Có backup thành công không có nghĩa application hiện đang sống. Application đang sống cũng không chứng minh backup đã chạy thành công.

Flow 2 phải trả lời cho từng application:

```text
Application nào?
Backup gần nhất có thành công trong 26 giờ không?
Application có trả health response hợp lệ ngay lúc kiểm tra không?
HTTP status là gì?
Thời điểm kiểm tra là khi nào?
```

## 3. Ma trận trạng thái

| Backup | Application | Ý nghĩa | Mức xử lý |
|---|---|---|---|
| `success` | `healthy` | Backup và application đều bình thường | Ghi kết quả tổng hợp, không gửi cảnh báo High |
| `success` | `reachable` | Không có readiness API nhưng URL ứng dụng trả response mong đợi | Ghi nhận app truy cập được, không khẳng định dependency bên trong healthy |
| `success` | `unhealthy` hoặc `unreachable` | Backup đã chạy nhưng application hiện có vấn đề | Cảnh báo application health |
| `success` | `not_configured` | Chưa có URL hoặc endpoint để kiểm tra | Báo khoảng trống monitoring, không kết luận app đã chết |
| `missing` | `healthy` | Application đang sống nhưng backup thiếu hoặc Flow 1 không ghi log | Cảnh báo backup |
| `missing` | `reachable` hoặc `not_configured` | Không xác nhận được backup; health chỉ có mức thấp hoặc chưa cấu hình | Cảnh báo backup, không suy diễn app down |
| `missing` | `unhealthy` hoặc `unreachable` | Vừa thiếu backup vừa không xác nhận được application sống | Cảnh báo Critical, ưu tiên xử lý |

Không được gộp hai trạng thái thành một Boolean duy nhất. Báo cáo phải hiển thị cả `backup_status` và `health_status`.

## 4. Kiến trúc tổng thể

```text
Recurrence 09:00 Asia/Ho_Chi_Minh
Get items từ DB_Backup_Log trong 26 giờ
Initialize ExpectedApps
Initialize MissingBackupSites
Initialize UnhealthyApps
Initialize UnmonitoredApps
Initialize CheckResults
Initialize các Current* variables
For each expected app, concurrency = 1
  Reset Current* variables
  Filter success rows của app hiện tại
  Đánh giá backup_status
  Switch health_mode
    readiness
      Validate health_url
      HTTP GET, Parse JSON và đánh giá status
    http_probe
      Validate health_url
      HTTP GET và đánh giá status code
    none
      Set not_configured và không gọi HTTP
  Finalize result
    Append một object kết quả tổng hợp vào CheckResults
Format CheckResults thành các dòng báo cáo
Filter các CheckResults không hoàn toàn healthy
Condition: có ít nhất một problem result
  True
    Teams mention với kết quả tổng hợp
    Email High importance với kết quả tổng hợp
  False
    Ghi hoặc gửi summary bình thường theo chính sách vận hành
```

Tên action khuyến nghị:

```text
Get_items
Initialize_ExpectedApps
Initialize_MissingBackupSites
Initialize_UnhealthyApps
Initialize_UnmonitoredApps
Initialize_CheckResults
For_each_expected_app
Filter_success_rows
Condition_backup_missing
Scope_try_readiness
Call_readiness_API
Scope_evaluate_readiness_payload
Parse_readiness_response
Condition_readiness_response
Scope_catch_readiness_transport
Scope_catch_readiness_payload
Scope_try_http_probe
Call_http_probe
Scope_evaluate_http_probe
Condition_http_probe_200
Scope_catch_http_probe
Scope_finalize_result
Append_check_result
Format_result_lines
Filter_problem_results
Condition_any_problem
```

Tên nội bộ trong expression có thể khác tên hiển thị. Luôn kiểm tra `Code view` trước khi copy expression.

## 5. Recurrence

| Setting | Value |
|---|---|
| Frequency | Day |
| Interval | 1 |
| Time zone | `(UTC+07:00) Bangkok, Hanoi, Jakarta` |
| At these hours | `9` |
| At these minutes | `0` |

Backup dự kiến chạy khoảng 02:00 giờ Việt Nam. Flow 2 chạy lúc 09:00 để có thời gian hoàn tất backup và để người phụ trách nhận cảnh báo trong giờ làm việc.

Application health signal được kiểm tra tại khoảng 09:00 nếu app có mode `readiness` hoặc `http_probe`, không phải tại thời điểm backup lúc 02:00. Báo cáo phải ghi rõ hai ý nghĩa thời gian này.

## 6. Chiến lược health check theo mức quan sát

Không giả định mọi application hiện có health API. Khi chưa nắm toàn bộ hệ thống, inventory phải cho phép ba chế độ:

| health_mode | Dữ liệu cần có | Kết quả tốt | Mức bảo đảm |
|---|---|---|---|
| `readiness` | Readiness API chuẩn | `healthy` | Xác nhận app và các dependency mà endpoint kiểm tra |
| `http_probe` | Một URL HTTPS ổn định trả `200` | `reachable` | Chỉ xác nhận route/web server phản hồi, không chứng minh toàn bộ app healthy |
| `none` | Không cần URL | `not_configured` | Không có kết luận về trạng thái app; chỉ ghi khoảng trống monitoring |

Nguyên tắc rollout:

1. Bắt đầu bằng inventory tất cả site với `health_mode=none`.
2. App nào đã có readiness API thì chuyển sang `readiness`.
3. App chưa có readiness nhưng biết URL ổn định thì dùng `http_probe`.
4. App chưa biết URL giữ `none`; không gọi HTTP và không kết luận app chết.
5. Theo dõi tỷ lệ coverage và bổ sung readiness endpoint dần, không chặn việc hoàn thiện kiểm tra backup.

### Mode `readiness`

Endpoint khuyến nghị:

```text
GET https://<application-host>/health/ready
```

Response thành công chuẩn:

```http
HTTP/1.1 200 OK
Content-Type: application/json
```

```json
{
  "status": "healthy",
  "service": "timesheet_misa",
  "version": "1.0.0",
  "database": "up"
}
```

Điều kiện `healthy` tối thiểu:

```text
HTTP status = 200
body.status = healthy
```

Phân loại kết quả của mode `readiness`:

| Tình huống | health_status |
|---|---|
| HTTP `200`, body `status=healthy` | `healthy` |
| HTTP `200`, body có `status` khác `healthy` | `unhealthy` |
| HTTP `2xx` nhưng body thiếu hoặc sai schema | `unhealthy` |
| HTTP `4xx` hoặc `5xx` | `unreachable` |
| DNS, TLS, connection error | `unreachable` |
| Timeout | `unreachable` |
| Mode `readiness` nhưng thiếu `health_url` | `config_error` |

### Mode `http_probe`

Gọi HTTP GET đến một URL HTTPS ổn định của application. Nếu URL trả HTTP `200`, đặt:

```text
health_status = reachable
```

Không Parse JSON và không đổi `reachable` thành `healthy`. Một trang login hoặc reverse proxy trả `200` chỉ chứng minh đường HTTP đang phản hồi.

Nếu URL probe timeout, DNS/TLS lỗi hoặc trả status ngoài giá trị mong đợi, đặt `unreachable`.

### Mode `none`

Không gọi HTTP. Đặt:

```text
health_status = not_configured
health_http_code = 0
```

Thêm app vào `UnmonitoredApps`, không thêm vào `UnhealthyApps`. `not_configured` phải xuất hiện trong summary coverage nhưng không tự tạo cảnh báo High về app down.

### Không thể bảo đảm app sống khi không có tín hiệu

Nếu không có readiness API, URL public, heartbeat, agent trên host hoặc monitoring system khác thì Flow 2 không có dữ liệu để xác định app đang sống. Backup database thành công chỉ chứng minh database có thể được dump; nó không chứng minh web/API application đang chạy.

Các lựa chọn bổ sung trong tương lai:

1. Cho application gửi heartbeat định kỳ vào SharePoint hoặc một flow riêng.
2. Dùng agent trên VPS kiểm tra Docker/systemd rồi gửi trạng thái tổng hợp.
3. Dùng monitoring platform chuyên dụng và đưa alert/result về Teams.
4. Bổ sung `/health/ready` dần khi owner của từng application được xác định.

### Yêu cầu đối với endpoint

- Endpoint phải truy cập được từ Microsoft Power Automate cloud.
- Không dùng `localhost`, IP private hoặc hostname chỉ phân giải trong Docker/VPS nếu không có On-premises Data Gateway hay cơ chế kết nối private tương ứng.
- Dùng HTTPS với certificate hợp lệ.
- Response phải nhanh, khuyến nghị dưới 5 giây.
- Không trả secret, connection string, stack trace, thông tin user hoặc dữ liệu nhạy cảm.
- Nên kiểm tra readiness thực tế của application và dependency quan trọng như database, thay vì chỉ trả `200` cố định.
- Không thực hiện tác vụ nặng, ghi dữ liệu hoặc thay đổi trạng thái hệ thống.
- Không nhận URL health từ request bên ngoài. URL phải đến từ inventory tin cậy để tránh SSRF.
- Nếu endpoint cần authentication, không hard-code token trong `ExpectedApps`; dùng connection, environment variable hoặc secret store được Power Automate quản lý và bật Secure Inputs/Outputs cho action HTTP.

### Licensing và network

Action HTTP tiêu chuẩn thường là Premium connector. Phải xác nhận Power Automate license của environment trước khi triển khai production.

Nếu application chỉ nằm trong private network, lựa chọn triển khai gồm:

1. Expose một readiness endpoint tối giản qua HTTPS và giới hạn truy cập phù hợp.
2. Dùng On-premises Data Gateway nếu connector và mô hình network hỗ trợ.
3. Đặt API gateway hoặc monitoring endpoint trung gian có thể được Power Automate gọi.
4. Dùng một monitoring service riêng gọi private endpoint rồi trả kết quả an toàn cho Flow 2.

## 7. Get items từ `DB_Backup_Log`

Thiết lập:

| Setting | Value |
|---|---|
| Site Address | SharePoint site chứa `DB_Backup_Log` |
| List Name | `DB_Backup_Log`, có thể hiển thị dưới dạng GUID trong New Designer |
| Order By | `Created desc` |
| Top Count | Để trống trong production; chỉ giới hạn tạm khi debug |

Trong Settings của `Get items`, bật Pagination và đặt Threshold đủ lớn cho toàn bộ volume có thể phát sinh trong 26 giờ, ví dụ `5000`. Không dùng `Top Count=100` trong production vì nhiều lần chạy thử hoặc retry có thể làm một site hợp lệ bị đẩy ra khỏi 100 row đầu và tạo cảnh báo thiếu backup giả.

Filter Query 26 giờ:

```text
concat(
  'Created ge datetime''',
  formatDateTime(addHours(utcNow(), -26), 'yyyy-MM-ddTHH:mm:ssZ'),
  ''''
)
```

Nếu SharePoint connector không chấp nhận tiền tố `datetime`, thử:

```text
concat(
  'Created ge ''',
  formatDateTime(addHours(utcNow(), -26), 'yyyy-MM-ddTHH:mm:ssZ'),
  ''''
)
```

### Vì sao dùng 26 giờ

| Lịch backup | Cửa sổ | Lý do |
|---|---|---|
| Hằng ngày lúc 02:00 | 26 giờ | 24 giờ cộng thời gian dự phòng cho randomized delay, thời gian chạy và độ trễ webhook |

### Lưu ý giới hạn kết quả

Trong lúc test, Flow 1 có thể tạo nhiều row. Nếu đặt Top Count và có nhiều row mới hơn row cần tìm, một site hợp lệ có thể bị loại khỏi kết quả dù vẫn tồn tại trong SharePoint.

Khi debug:

- Tạm bỏ Filter Query để xác nhận list và field mapping.
- Bỏ Top Count và dùng Pagination nếu cần đọc toàn bộ cửa sổ 26 giờ.
- Kiểm tra raw output, không chỉ nhìn SharePoint UI.

## 8. Inventory `ExpectedApps`

Kiến trúc cũ dùng array string `ExpectedSites`. Kiến trúc mới dùng array object `ExpectedApps` để gắn site với chế độ kiểm tra và URL nếu có.

Type:

```text
Array
```

Ví dụ cấu trúc:

```json
[
  {
    "site": "timesheet_misa",
    "health_mode": "readiness",
    "health_url": "https://<timesheet-host>/health/ready"
  },
  {
    "site": "legacy_web_app",
    "health_mode": "http_probe",
    "health_url": "https://<application-host>/"
  },
  {
    "site": "unknown_app",
    "health_mode": "none",
    "health_url": null
  }
]
```

Không dùng một URL ngẫu nhiên trên Internet để test health. Nếu cần test `unreachable`, dùng endpoint do tổ chức kiểm soát có thể chủ động trả `503` hoặc timeout.

Khi đưa vào production, trường `site` phải khớp chính xác với cột đầu tiên của **cả hai** inventory:

```text
/opt/mbc-backup/sites.conf         # PostgreSQL
/opt/mbc-backup/sites-files.conf   # database dạng file (SQLite)
```

Lấy đầy đủ danh sách site bằng một lệnh:

```bash
cat /opt/mbc-backup/sites.conf /opt/mbc-backup/sites-files.conf \
  | grep -vE '^[[:space:]]*(#|$)' | cut -d'|' -f1
```

Site dạng file thường thuộc application của team khác. Nếu chưa biết health endpoint thì để `health_mode: none`: Flow 2 vẫn kiểm tra được backup của site đó, chỉ là không kết luận gì về tình trạng application.

`health_mode` chỉ nhận `readiness`, `http_probe` hoặc `none`. `health_url` bắt buộc với hai mode đầu và được phép `null` với mode `none`.

Production hiện có khoảng 12 site. Không dùng nguyên danh sách 9 site mẫu trong tài liệu cũ mà không đối chiếu inventory thực tế.

Về lâu dài nên chuyển inventory này sang SharePoint list `DB_Backup_Targets` hoặc nguồn cấu hình trung tâm với các cột:

| Column | Type | Ý nghĩa |
|---|---|---|
| `Title` | Text | Tên site/application |
| `HealthMode` | Choice | `readiness`, `http_probe`, `none` |
| `HealthUrl` | Hyperlink hoặc Text | Endpoint hoặc URL probe; được để trống với mode `none` |
| `Enabled` | Yes/No | Có kiểm tra target này không |
| `OwnerEmail` | Text | Người nhận cảnh báo cụ thể nếu cần |

Không lưu API secret trực tiếp trong list này.

## 9. Các biến cần khởi tạo

### Biến kết quả toàn flow

| Variable | Type | Initial value | Ý nghĩa |
|---|---|---|---|
| `MissingBackupSites` | Array | `[]` | Danh sách site không có backup success |
| `UnhealthyApps` | Array | `[]` | Danh sách app health không đạt |
| `UnmonitoredApps` | Array | `[]` | Danh sách app chưa có readiness endpoint hoặc URL probe |
| `CheckResults` | Array | `[]` | Kết quả backup và health tổng hợp cho từng app |

### Biến trạng thái của iteration hiện tại

Power Automate không cho Initialize variable bên trong Apply to each. Vì vậy các biến sau phải initialize trước vòng lặp và dùng Set variable để reset ở đầu mỗi iteration.

| Variable | Type | Initial value |
|---|---|---|
| `CurrentBackupStatus` | String | `unknown` |
| `CurrentBackupLastSuccess` | String | chuỗi rỗng |
| `CurrentHealthStatus` | String | `unknown` |
| `CurrentHealthHttpCode` | Integer | `0` |
| `CurrentHealthDetail` | String | chuỗi rỗng |

Đầu mỗi iteration, reset:

```text
CurrentBackupStatus = unknown
CurrentBackupLastSuccess = empty
CurrentHealthStatus = unknown
CurrentHealthHttpCode = 0
CurrentHealthDetail = empty
```

Vì các biến Current dùng chung giữa các iteration, `For each expected app` bắt buộc chạy tuần tự.

## 10. Vòng lặp `For each expected app`

Input:

```text
variables('ExpectedApps')
```

Bật:

```text
Concurrency Control: On
Degree of Parallelism: 1
```

App hiện tại:

```text
items('For_each_expected_app')?['site']
```

Health URL hiện tại:

```text
items('For_each_expected_app')?['health_url']
```

Health mode hiện tại:

```text
toLower(string(items('For_each_expected_app')?['health_mode']))
```

Không chọn token `Current item` chung chung. Luôn dùng expression có tên vòng lặp để tránh nhầm scope.

## 11. Kiểm tra backup trong vòng lặp

### Filter success rows

From:

```text
body('Get_items')?['value']
```

Nếu SharePoint Choice trả object có `Value`:

```text
and(
  equals(
    item()?['Site']?['Value'],
    items('For_each_expected_app')?['site']
  ),
  equals(
    item()?['Status']?['Value'],
    'success'
  )
)
```

Nếu SharePoint Choice trả string:

```text
and(
  equals(
    item()?['Site'],
    items('For_each_expected_app')?['site']
  ),
  equals(
    item()?['Status'],
    'success'
  )
)
```

Phải kiểm tra `Get items` -> `Show raw outputs` -> `body.value` để biết dùng dạng nào.

### Hai loại Current item

Trong Filter Array:

```text
item()
```

là từng SharePoint row.

Trong vòng lặp ngoài:

```text
items('For_each_expected_app')
```

là object application hiện tại.

Nếu dùng nhầm `item()` cho cả hai vế, Filter sẽ so sánh sai context và trả array rỗng cho mọi app.

### Condition backup missing

Expression bên trái:

```text
length(body('Filter_success_rows'))
```

Operator và giá trị:

```text
is equal to
0
```

Nếu nhập toàn bộ bằng Advanced expression, dùng:

```text
equals(length(body('Filter_success_rows')), 0)
```

Nếu True:

```text
Set CurrentBackupStatus = missing
Append items('For_each_expected_app')?['site'] vào MissingBackupSites
```

Nếu False:

```text
Set CurrentBackupStatus = success
Set CurrentBackupLastSuccess = first(body('Filter_success_rows'))?['Created']
```

Do `Get items` được sort `Created desc`, row đầu tiên trong kết quả filter là success mới nhất trong cửa sổ đang xét.

Chỉ giữ một dòng trong Condition. Xóa dòng trống `Choose a value is equal to Choose a value` nếu New Designer tự tạo.

## 12. Chọn health mode và kiểm tra URL

Thêm Switch theo:

```text
toLower(string(items('For_each_expected_app')?['health_mode']))
```

### Case `none`

```text
Set CurrentHealthStatus = not_configured
Set CurrentHealthDetail = No application health signal is configured
Append items('For_each_expected_app')?['site'] vào UnmonitoredApps
Không gọi HTTP
```

### Case `readiness` và `http_probe`

Trước khi gọi HTTP, kiểm tra URL rỗng hoặc không dùng HTTPS:

```text
or(
  empty(trim(string(items('For_each_expected_app')?['health_url']))),
  not(
    startsWith(
      toLower(trim(string(items('For_each_expected_app')?['health_url']))),
      'https://'
    )
  )
)
```

Nếu True:

```text
Set CurrentHealthStatus = config_error
Set CurrentHealthDetail = Missing or invalid health_url
Append items('For_each_expected_app')?['site'] vào UnhealthyApps
Bỏ qua HTTP
```

Nếu False, chạy bộ action có tên riêng của mode tương ứng. Không dùng chung tên action giữa hai Switch case vì Power Automate sẽ tự thêm suffix và làm expression khó kiểm soát.

Với mode `readiness`, sau HTTP success chạy Parse JSON và yêu cầu `status=healthy` như mục 13.

Với mode `http_probe`, không Parse JSON. Nếu HTTP trả `200`, set:

```text
CurrentHealthStatus = reachable
CurrentHealthDetail = Application URL returned HTTP 200
```

### Default case

Nếu `health_mode` có giá trị khác `readiness`, `http_probe` hoặc `none`:

```text
Set CurrentHealthStatus = config_error
Append items('For_each_expected_app')?['site'] vào UnhealthyApps
```

Giá trị mode không hợp lệ là lỗi cấu hình. Khác với mode `none`, nó phải tạo cảnh báo để inventory được sửa.

`Scope_finalize_result` phải đặt sau toàn bộ Switch, không đặt riêng trong một case. Nhờ đó mọi app, kể cả `none`, đều tạo đúng một kết quả tổng hợp.

Trong production nên kiểm tra thêm hostname bằng allowlist lấy từ inventory tin cậy. Không gọi một URL chỉ vì nó bắt đầu bằng `https://` nếu URL đó có thể bị người dùng bên ngoài thay đổi.

## 13. Case readiness - gọi health API

`Scope_try_readiness` chỉ chịu trách nhiệm thực hiện HTTP transport. Không đặt Parse JSON trong Try này, vì payload sai schema phải được phân loại là `unhealthy`, không phải lỗi kết nối `unreachable`.

### HTTP action

Tên:

```text
Call_readiness_API
```

Thiết lập:

| Setting | Value |
|---|---|
| Method | `GET` |
| URI | `items('For_each_expected_app')?['health_url']` |
| Timeout | `PT10S` hoặc giá trị ngắn phù hợp |
| Retry Policy | Fixed, tối đa 1-2 retry với khoảng chờ ngắn |

Không retry quá lâu vì Flow 2 phải kiểm tra nhiều application và cần hoàn thành trong thời gian hợp lý.

Sau HTTP success, trong nhánh Evaluate set:

```text
CurrentHealthHttpCode = int(outputs('Call_readiness_API')?['statusCode'])
```

### Nhánh Evaluate response của mode `readiness`

Tạo `Scope_evaluate_readiness_payload` chạy sau `Scope_try_readiness` khi `is successful`.

### Parse và Condition health response

Sau khi HTTP action thành công, dùng `Parse JSON` với schema tối thiểu yêu cầu field `status` là string. Sau đó đánh giá response đã parse, không đọc trực tiếp một body chưa biết kiểu trong Condition.

Schema tối thiểu:

```json
{
  "type": "object",
  "properties": {
    "status": {
      "type": "string"
    }
  },
  "required": ["status"]
}
```

Với contract chuẩn `body.status=healthy`:

```text
and(
  equals(outputs('Call_readiness_API')?['statusCode'], 200),
  equals(
    toLower(string(body('Parse_readiness_response')?['status'])),
    'healthy'
  )
)
```

Nếu True:

```text
Set CurrentHealthStatus = healthy
Set CurrentHealthDetail = Health endpoint returned healthy
```

Nếu False:

```text
Set CurrentHealthStatus = unhealthy
Set CurrentHealthDetail = Health endpoint returned an unexpected payload
Append items('For_each_expected_app')?['site'] vào UnhealthyApps
```

Không coi HTTP `200` đơn thuần là đủ nếu endpoint đã thống nhất contract JSON. Một reverse proxy có thể trả trang HTML `200` trong khi application phía sau không sẵn sàng.

Đặt `Parse_readiness_response` và `Condition_readiness_response` trong scope `Scope_evaluate_readiness_payload`. Thêm `Scope_catch_readiness_payload` chạy sau scope này khi failed hoặc timed out. Trong payload Catch:

```text
Set CurrentHealthStatus = unhealthy
Append items('For_each_expected_app')?['site'] vào UnhealthyApps
Set CurrentHealthDetail = Health endpoint returned an invalid response schema
```

Việc append phải đứng trước action diagnostic. Nhờ đó response HTML, JSON sai schema hoặc expression lỗi vẫn tạo cảnh báo application health thay vì làm flow dừng im lặng.

## 14. Catch readiness và case http_probe

### Catch transport của readiness

Sau `Scope_try_readiness`, tạo hai parallel branches: Evaluate chỉ chạy khi Try successful và `Scope_catch_readiness_transport` chỉ chạy khi Try failed hoặc timed out.

Run after của `Scope_catch_readiness_transport`:

```text
has failed
has timed out
```

Trong Catch:

```text
Set CurrentHealthStatus = unreachable
Append items('For_each_expected_app')?['site'] vào UnhealthyApps
Set CurrentHealthDetail = string(result('Scope_try_readiness'))
```

Giữ `CurrentHealthHttpCode=0` từ bước reset nếu request không tạo được HTTP response. Nếu cần lấy status code của response `4xx` hoặc `5xx`, đặt việc đọc `outputs('Call_readiness_API')?['statusCode']` trong một action hoặc scope best-effort riêng sau khi đã set `unreachable` và append `UnhealthyApps`.

### Case `http_probe`

Tạo bộ action riêng:

```text
Scope_try_http_probe
  Call_http_probe
Scope_evaluate_http_probe
  Set CurrentHealthHttpCode
  Condition_http_probe_200
Scope_catch_http_probe
```

Thiết lập `Call_http_probe`:

| Setting | Value |
|---|---|
| Method | `GET` |
| URI | `items('For_each_expected_app')?['health_url']` |
| Timeout | `PT10S` hoặc giá trị ngắn phù hợp |
| Retry Policy | Fixed, tối đa 1-2 retry với khoảng chờ ngắn |

`Scope_evaluate_http_probe` chạy sau `Scope_try_http_probe` khi successful. Set:

```text
CurrentHealthHttpCode = int(outputs('Call_http_probe')?['statusCode'])
```

Condition:

```text
equals(outputs('Call_http_probe')?['statusCode'], 200)
```

Nếu True:

```text
Set CurrentHealthStatus = reachable
Set CurrentHealthDetail = Application URL returned HTTP 200
```

Nếu False:

```text
Set CurrentHealthStatus = unreachable
Append items('For_each_expected_app')?['site'] vào UnhealthyApps
Set CurrentHealthDetail = Application URL returned an unexpected status
```

`Scope_catch_http_probe` chạy sau `Scope_try_http_probe` khi failed hoặc timed out. Trong Catch, set `unreachable` và append `UnhealthyApps` trước khi đọc diagnostic, giống readiness transport Catch.

Mục tiêu của Catch là bảo đảm một app timeout, DNS lỗi, TLS lỗi hoặc trả `5xx` không làm dừng vòng lặp và không ngăn các app còn lại được kiểm tra.

Không đưa toàn bộ raw response hoặc stack trace vào Teams nếu có khả năng chứa thông tin nhạy cảm. Raw detail chỉ nên xem trong run history hoặc log được kiểm soát.

## 15. Scope Finalize - tạo kết quả tổng hợp

`Scope_finalize_result` đặt trực tiếp sau toàn bộ Switch `health_mode` và ở ngoài mọi case. Cấu hình Run after cho Switch khi:

```text
is successful
has failed
has timed out
is skipped
```

Trong các mode có URL, Catch transport sẽ `skipped` khi Try thành công và Evaluate sẽ `skipped` khi Try thất bại. Với mode `none`, toàn bộ HTTP action không được gọi. Cho phép cả `skipped` giúp Finalize vẫn tạo một record cho mọi app.

Tạo action Compose `Build_check_result` dưới dạng object bằng full expression values trong Code view:

```json
{
  "site": "@items('For_each_expected_app')?['site']",
  "backup_status": "@variables('CurrentBackupStatus')",
  "backup_last_success": "@variables('CurrentBackupLastSuccess')",
  "health_mode": "@items('For_each_expected_app')?['health_mode']",
  "health_status": "@variables('CurrentHealthStatus')",
  "health_http_code": "@variables('CurrentHealthHttpCode')",
  "checked_at": "@utcNow()"
}
```

Sau đó Append vào `CheckResults` bằng:

```text
outputs('Build_check_result')
```

Trong JSON định nghĩa action, expression vẫn nằm trong dấu nháy để JSON hợp lệ. Tiền tố full expression `@variables(...)`, không phải interpolation `@{variables(...)}`, giúp Power Automate giữ kiểu Integer của `CurrentHealthHttpCode`. Kiểm tra output của Compose và Array variable để bảo đảm giá trị được lưu thành object, không phải một JSON string. New Designer có thể xử lý việc paste object khác nhau, vì vậy Code view và run output là nguồn xác nhận cuối cùng.

Không bắt buộc đưa `CurrentHealthDetail` vào `CheckResults` nếu nội dung có thể dài hoặc nhạy cảm. Có thể chỉ dùng detail trong run history.

Ví dụ kết quả:

```json
[
  {
    "site": "timesheet_misa",
    "backup_status": "success",
    "backup_last_success": "2026-08-06T02:33:00Z",
    "health_mode": "readiness",
    "health_status": "healthy",
    "health_http_code": 200,
    "checked_at": "2026-08-07T02:00:10Z"
  },
  {
    "site": "site_khong_ton_tai",
    "backup_status": "missing",
    "backup_last_success": "",
    "health_mode": "readiness",
    "health_status": "unreachable",
    "health_http_code": 503,
    "checked_at": "2026-08-07T02:00:20Z"
  }
]
```

## 16. Format kết quả trên workflow

Sau vòng lặp, dùng Data Operation `Select` với tên `Format_result_lines`.

From:

```text
variables('CheckResults')
```

Chuyển Select sang text mode và dùng:

```text
concat(
  item()?['site'],
  ' | Backup: ', item()?['backup_status'],
  if(
    empty(item()?['backup_last_success']),
    '',
    concat(' (last success: ', item()?['backup_last_success'], ')')
  ),
  ' | App: ', item()?['health_status'],
  ' (mode: ', item()?['health_mode'], ')',
  ' | HTTP: ', string(item()?['health_http_code'])
)
```

Ghép các dòng bằng:

```text
join(body('Format_result_lines'), decodeUriComponent('%0A'))
```

Ví dụ output:

```text
timesheet_misa | Backup: success (last success: 2026-08-06T02:33:00Z) | App: healthy (mode: readiness) | HTTP: 200
site_khong_ton_tai | Backup: missing | App: unreachable (mode: readiness) | HTTP: 503
```

Kết quả này phải xuất hiện trong run history. Khi có lỗi, cùng nội dung được đưa vào Teams và email để người nhận thấy cả trạng thái backup lẫn application.

## 17. Condition cảnh báo cuối flow

Không dùng riêng `MissingBackupSites` và `UnhealthyApps` để quyết định có cảnh báo hay không. Hai array đó phục vụ phần trình bày. Nếu một action nội bộ lỗi trước khi append vào array, trạng thái có thể là `unknown` và cảnh báo sẽ bị bỏ sót.

Sau vòng lặp, thêm Filter Array `Filter_problem_results`.

From:

```text
variables('CheckResults')
```

Advanced expression:

```text
or(
  not(equals(item()?['backup_status'], 'success')),
  contains(
    createArray('unhealthy', 'unreachable', 'config_error', 'unknown'),
    item()?['health_status']
  )
)
```

Expression này cảnh báo backup `missing` và các health status `unhealthy`, `unreachable`, `config_error`, `unknown`. Hai trạng thái `reachable` và `not_configured` không được xem là app-down incident.

`not_configured` vẫn phải xuất hiện trong summary và danh sách `UnmonitoredApps`. Có thể gửi một báo cáo coverage riêng hằng tuần, nhưng không gửi High alert hằng ngày chỉ vì app chưa có endpoint.

Đặt phần đánh giá cuối trong một scope chạy sau `For_each_expected_app` với các trạng thái `is successful`, `has failed`, `has timed out` và `is skipped`. Condition cuối phải kiểm tra cả problem results, inventory rỗng và số result không khớp số app dự kiến:

```text
or(
  equals(length(variables('ExpectedApps')), 0),
  not(
    equals(
      length(variables('CheckResults')),
      length(variables('ExpectedApps'))
    )
  ),
  greater(length(body('Filter_problem_results')), 0)
)
```

Nhờ kiểm tra count, việc một iteration không tạo được result cũng sinh cảnh báo thay vì bị xem là healthy.

Nếu True, gửi Teams mention và email High importance.

Teams message mẫu:

```text
[BACKUP / APP HEALTH ALERT]

Kết quả kiểm tra:
@{join(body('Format_result_lines'), decodeUriComponent('%0A'))}

Thiếu backup:
@{if(empty(variables('MissingBackupSites')), 'None', join(variables('MissingBackupSites'), ', '))}

Application không healthy:
@{if(empty(variables('UnhealthyApps')), 'None', join(variables('UnhealthyApps'), ', '))}

Application chưa cấu hình health monitoring:
@{if(empty(variables('UnmonitoredApps')), 'None', join(variables('UnmonitoredApps'), ', '))}

Kiểm tra backup:
1. systemctl list-timers mbc-backup.timer
2. journalctl -u mbc-backup -n 200
3. FLOW_WEBHOOK_URL còn hợp lệ không

Kiểm tra application:
1. DNS, TLS và reverse proxy
2. Container hoặc service status
3. Application log
4. Database và dependency của readiness endpoint

Runbook: /opt/mbc-backup/runbook.md
```

Email subject:

```text
[BACKUP / APP HEALTH ALERT] Problems: @{length(body('Filter_problem_results'))} | Results: @{length(variables('CheckResults'))}/@{length(variables('ExpectedApps'))}
```

Nếu False, vẫn giữ `CheckResults` trong run history. Có thể gửi một Teams summary ngắn hằng ngày nếu chính sách vận hành yêu cầu, nhưng tránh tạo quá nhiều thông báo khiến cảnh báo thật bị bỏ qua.

## 18. Debug vấn đề backup hiện tại

Trong lần test ban đầu, cả `timesheet_misa` và `site_khong_ton_tai` đều bị append. Điều đó có nghĩa `Filter_success_rows` đã trả array rỗng trong cả hai iteration tại lần chạy đó.

Trước khi chạy lại, phải tạo hoặc xác nhận một row `timesheet_misa/success` mới nằm trong 26 giờ gần nhất. Row ngày 05/08 hiện đã quá cũ; nếu chỉ còn row đó thì việc append `timesheet_misa` vào ngày 07/08 là kết quả đúng, không phải lỗi Filter.

### Kiểm tra Get items

Mở:

```text
Run history
Get items
Show raw outputs
body.value
```

Xác nhận:

- `body.value` không rỗng.
- Có row `timesheet_misa` với `Status=success` và `Created` còn nằm trong 26 giờ.
- Xác định `Site` và `Status` là string hay object có `Value`.

Có thể thêm Compose tạm:

```text
Debug_get_items_count = length(body('Get_items')?['value'])
Debug_get_items_data = body('Get_items')?['value']
```

### Kiểm tra Filter trong iteration `timesheet_misa`

Mở raw inputs và raw outputs của `Filter_success_rows`.

Nếu `from=[]`, lỗi nằm ở `Get items`, Filter Query, pagination, cửa sổ thời gian hoặc list mapping.

Nếu `from` có row nhưng output `[]`, lỗi nằm ở expression, kiểu Choice hoặc scope `Current item`.

Nếu Filter output có row nhưng Condition vẫn True, kiểm tra Code view của Condition và chỉ giữ:

```text
equals(length(body('Filter_success_rows')), 0)
```

Sau khi đổi từ `ExpectedSites` string sang `ExpectedApps` object, vế so sánh bắt buộc là:

```text
items('For_each_expected_app')?['site']
```

Không dùng expression cũ trả toàn bộ object:

```text
items('For_each_expected_app')
```

Nếu so sánh một string Site với toàn bộ object app, Filter sẽ luôn trả rỗng.

## 19. Test bắt buộc

### Test A - backup success, app healthy

Input:

```text
DB_Backup_Log có timesheet_misa/success được tạo trong 26 giờ gần nhất
Health API trả 200 và {"status":"healthy"}
```

Expected:

```text
backup_status = success
health_status = healthy
Không nằm trong MissingBackupSites
Không nằm trong UnhealthyApps
```

### Test B - backup missing, app healthy

Input:

```text
Không có success row cho site test
Health API trả 200 và {"status":"healthy"}
```

Expected:

```text
backup_status = missing
health_status = healthy
Có trong MissingBackupSites
Không nằm trong UnhealthyApps
```

### Test C - backup success, app unhealthy

Input:

```text
Có success row
Health API trả 200 và {"status":"unhealthy"}
```

Expected:

```text
backup_status = success
health_status = unhealthy
Không nằm trong MissingBackupSites
Có trong UnhealthyApps
```

### Test D - backup success, health HTTP 503

Expected:

```text
backup_status = success
health_status = unreachable
health_http_code = 503 nếu best-effort diagnostic đọc được response, nếu không là 0
Flow tiếp tục kiểm tra app tiếp theo
```

### Test E - health timeout hoặc DNS lỗi

Expected:

```text
health_status = unreachable
health_http_code = 0 nếu không có HTTP response
Flow tiếp tục kiểm tra app tiếp theo
```

### Test F - mode readiness thiếu health_url

Expected:

```text
health_status = config_error
App nằm trong UnhealthyApps
Không gọi HTTP với URI rỗng
```

### Test G - cả backup và app đều lỗi

Expected:

```text
Site nằm trong MissingBackupSites
Site nằm trong UnhealthyApps
Teams và email hiển thị cả hai trạng thái
```

### Test H - chưa biết endpoint hoặc URL app

Input:

```json
{
  "site": "unknown_app",
  "health_mode": "none",
  "health_url": null
}
```

Expected:

```text
health_status = not_configured
App nằm trong UnmonitoredApps
App không nằm trong UnhealthyApps
Không gọi HTTP
Không kết luận app down
```

### Test I - không có readiness nhưng có URL app

Input:

```text
health_mode = http_probe
URL trả HTTP 200
```

Expected:

```text
health_status = reachable
Không Parse JSON
Không khẳng định dependency bên trong healthy
```

### Kết quả test backup tối thiểu hiện tại

Với `timesheet_misa` có fresh success row và `site_khong_ton_tai` không có success row:

```json
{
  "MissingBackupSites": ["site_khong_ton_tai"]
}
```

Health result phụ thuộc endpoint test đã cấu hình, nhưng không được làm thay đổi kết quả backup trên.

## 20. Checklist nghiệm thu

- [ ] Flow 1 vẫn hoạt động và ghi row vào `DB_Backup_Log`.
- [ ] `ExpectedApps` là array object có `site`, `health_mode` và `health_url` khi mode cần URL.
- [ ] Inventory production khớp `/opt/mbc-backup/sites.conf`.
- [ ] Mỗi app đã được phân loại `readiness`, `http_probe` hoặc `none` dựa trên thông tin thực có.
- [ ] Endpoint/URL đã biết dùng HTTPS và không lộ dữ liệu nhạy cảm.
- [ ] Đã xác nhận license cho HTTP connector.
- [ ] `Get items` trả row trong 26 giờ gần nhất.
- [ ] `Get items` bật Pagination đủ cho toàn bộ volume 26 giờ và không bị giới hạn Top Count trong production.
- [ ] Raw output xác nhận đúng cấu trúc `Site` và `Status`.
- [ ] Filter dùng `items('For_each_expected_app')?['site']`.
- [ ] `timesheet_misa` có fresh success trong 26 giờ và không bị append vào `MissingBackupSites`.
- [ ] Site giả không có success bị append vào `MissingBackupSites`.
- [ ] Vòng lặp dùng concurrency degree `1`.
- [ ] HTTP có timeout và retry giới hạn.
- [ ] HTTP `200` chỉ healthy khi body `status=healthy`.
- [ ] Mode `http_probe` trả `reachable`, không trả `healthy`.
- [ ] Mode `none` trả `not_configured`, thêm vào `UnmonitoredApps` và không gọi HTTP.
- [ ] Response HTTP thành công nhưng body sai schema được phân loại `unhealthy` và vẫn tạo cảnh báo.
- [ ] HTTP `4xx`, `5xx`, DNS, TLS và timeout được Catch xử lý.
- [ ] Một health API lỗi không làm dừng việc kiểm tra app còn lại.
- [ ] `CheckResults` có cả backup status và health status cho từng app.
- [ ] `Filter_problem_results` cảnh báo backup không success và health `unhealthy`, `unreachable`, `config_error`, `unknown`; không coi `reachable` hoặc `not_configured` là app-down incident.
- [ ] Condition cuối kiểm tra problem results, inventory rỗng và số result không khớp số app dự kiến.
- [ ] Teams mention hiển thị kết quả tổng hợp khi có lỗi.
- [ ] Email High importance hiển thị kết quả tổng hợp khi có lỗi.
- [ ] Test đủ các case A-I, gồm readiness, URL probe và chưa cấu hình monitoring.
- [ ] Đã bỏ site và endpoint giả khỏi production configuration.

## 21. Thứ tự triển khai cho người tiếp quản

1. Không debug lại Flow 1; Flow 1 đã hoạt động.
2. Tạo hoặc xác nhận một row `timesheet_misa/success` mới còn trong cửa sổ 26 giờ.
3. Sửa dứt điểm Filter backup và xác nhận `MissingBackupSites` chỉ chứa `site_khong_ton_tai`.
4. Lập inventory mức quan sát hiện có: app nào có readiness, chỉ có URL hoặc chưa biết gì.
5. Chỉ chuẩn hóa response `{"status":"healthy"}` cho app đã có hoặc sẽ bổ sung readiness API.
6. Đổi `ExpectedSites` thành `ExpectedApps` array object.
7. Cập nhật Filter backup dùng `items('For_each_expected_app')?['site']`.
8. Thêm các biến `UnhealthyApps`, `UnmonitoredApps`, `CheckResults` và `Current*`.
9. Bật concurrency degree `1`.
10. Thêm Switch cho `readiness`, `http_probe`, `none` và validation URL khi cần.
11. Thêm Try/Catch cho các mode có HTTP.
12. Thêm Finalize để append kết quả tổng hợp cho mọi app.
13. Format `CheckResults` thành các dòng báo cáo.
14. Thêm `Filter_problem_results` và kiểm tra số result khớp số app dự kiến.
15. Thêm Condition cảnh báo chung cho backup và application health.
16. Chạy toàn bộ test A-I.
17. Thay inventory test bằng toàn bộ app production.

## 22. Giới hạn thiết kế

- Flow 2 không phân biệt chắc chắn backup không chạy với backup chạy nhưng Flow 1/webhook không ghi log được.
- Health API hoặc URL probe chỉ phản ánh trạng thái tại thời điểm được gọi, không chứng minh application đã healthy liên tục trước đó.
- Readiness endpoint tốt hơn ping TCP nhưng vẫn chỉ chính xác theo các dependency mà endpoint thực sự kiểm tra.
- Flow 2 phụ thuộc Power Automate, SharePoint, DNS và network từ Microsoft cloud.
- HTTP connector có thể cần Premium license.
- Inventory hard-code có nguy cơ lệch với runtime configuration.
- Chạy tuần tự an toàn cho Array variables nhưng tổng thời gian flow tăng theo số app và timeout. Với khoảng 12 app và timeout 10 giây, trường hợp nhiều app chết có thể kéo dài vài phút.
- Nếu cần monitoring theo phút, lịch sử uptime, latency, SLA hoặc nhiều region, nên dùng hệ thống monitoring chuyên dụng; Flow 2 phù hợp với dead-man check và summary hằng ngày.

## 23. Thông tin hệ thống liên quan

SharePoint:

```text
Document library: Backup_Database_Devs
Backup folder: DB_Backups
Log list: DB_Backup_Log
```

Runtime server:

```text
/opt/mbc-backup/.env
/opt/mbc-backup/sites.conf
/opt/mbc-backup/runbook.md
```

Các field backup Flow 2 sử dụng:

```text
Title
Site
Status
Created
```

Các giá trị backup Status hợp lệ:

```text
success
failed
fatal
```

Các giá trị health status do Flow 2 tạo:

```text
healthy
reachable
unhealthy
unreachable
not_configured
config_error
unknown
```

Flow 2 phải giữ hai kết quả độc lập và luôn hiển thị cùng nhau:

```text
backup_status
health_status
```
