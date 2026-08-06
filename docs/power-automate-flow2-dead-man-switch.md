# Power Automate Flow 2 - Backup Dead-man Switch

Tài liệu bàn giao và xử lý sự cố cho Flow 2 theo `MBC-SPEC-BACKUP-001 v0.2`, mục 5.6.

## 1. Trạng thái hiện tại

### Phần đã hoạt động

- Backup script đã upload được file lên SharePoint document library `Backup_Database_Devs`, folder `DB_Backups`.
- Flow 1 - `Backup Result Handler` đã hoạt động.
- Webhook của Flow 1 trả HTTP `202`.
- Flow 1 đã ghi được từng kết quả site vào SharePoint list `DB_Backup_Log`.
- Flow 1 đã xử lý được payload và các trạng thái cần thiết. Flow 1 không còn là vấn đề cần debug trong giai đoạn hiện tại.
- Trong `DB_Backup_Log` đã có row thành công dùng để kiểm thử Flow 2, ví dụ:

  ```text
  Title: 20260805_0233
  Site: timesheet_misa
  Status: success
  Created: 05/08/2026 02:33
  ```

### Vấn đề duy nhất còn lại

Flow 2 đang append cả hai site sau vào biến `MissingSites`:

```json
[
  "timesheet_misa",
  "site_khong_ton_tai"
]
```

Đây là kết quả sai vì `timesheet_misa` đã có row `success` trong `DB_Backup_Log`. Kết quả đúng phải là:

```json
[
  "site_khong_ton_tai"
]
```

Flow 2 chưa được coi là hoàn tất cho đến khi test trên cho kết quả đúng và phần cảnh báo cuối flow hoạt động.

## 2. Mục đích của Flow 2

Flow 1 chỉ báo cáo những gì backup script đã gửi lên. Nếu VPS chết, timer bị disable, script không chạy, mất mạng hoặc webhook không được gọi thì Flow 1 sẽ hoàn toàn im lặng.

Flow 2 chạy độc lập trong Power Automate và chủ động kiểm tra sự vắng mặt của tín hiệu backup thành công. Vì vậy Flow 2 vẫn chạy khi VPS không hoạt động.

Flow 2 phải trả lời câu hỏi:

> Trong 26 giờ gần nhất, mỗi site production có ít nhất một row `success` trong `DB_Backup_Log` hay không?

Nếu không có row `success`, site đó phải được thêm vào `MissingSites` và gửi cảnh báo.

Một row `failed` hoặc `fatal` không được xem là tín hiệu backup thành công.

## 3. Cấu trúc Flow 2 hiện tại

```text
Recurrence
Get items
Initialize ExpectedSites
Initialize MissingSites
For each expected site
  Filter success rows
  Condition: length(Filter success rows) = 0
    True
      Append to array variable MissingSites
    False
      Không làm gì
Condition sau vòng lặp: length(MissingSites) > 0
  True
    Gửi Teams mention
    Gửi email High importance
  False
    Không làm gì
```

Tên action nên được đặt rõ ràng để expression dễ đọc và tránh nhầm scope:

```text
Get_items
Initialize_ExpectedSites
Initialize_MissingSites
For_each_expected_site
Filter_success_rows
Append_missing_site
```

Tên hiển thị có thể chứa khoảng trắng, nhưng tên nội bộ trong expression thường được Power Automate đổi thành dấu gạch dưới. Luôn kiểm tra `Code view` nếu tên thực tế khác tài liệu.

## 4. Recurrence

| Setting | Value |
|---|---|
| Frequency | Day |
| Interval | 1 |
| Time zone | `(UTC+07:00) Bangkok, Hanoi, Jakarta` |
| At these hours | `9` |
| At these minutes | `0` |

Backup dự kiến chạy khoảng 02:00 giờ Việt Nam. Flow 2 chạy lúc 09:00 để người phụ trách có thể nhận và xử lý cảnh báo trong giờ làm việc.

## 5. Get items từ `DB_Backup_Log`

Thiết lập:

| Setting | Value |
|---|---|
| Site Address | SharePoint site đang chứa `DB_Backup_Log` |
| List Name | `DB_Backup_Log`, có thể hiển thị dưới dạng GUID trong New Designer |
| Order By | `Created desc` |
| Top Count | `100` |

Filter Query dự kiến cho cửa sổ 26 giờ:

```text
concat(
  'Created ge datetime''',
  formatDateTime(addHours(utcNow(), -26), 'yyyy-MM-ddTHH:mm:ssZ'),
  ''''
)
```

Nếu SharePoint connector không chấp nhận tiền tố `datetime`, thử dạng:

```text
concat(
  'Created ge ''',
  formatDateTime(addHours(utcNow(), -26), 'yyyy-MM-ddTHH:mm:ssZ'),
  ''''
)
```

### Vì sao dùng 26 giờ

| Lịch backup | Cửa sổ kiểm tra | Lý do |
|---|---|---|
| Hằng ngày lúc 02:00 | 26 giờ | 24 giờ cộng thời gian dự phòng cho `RandomizedDelaySec=900`, thời gian chạy và độ trễ webhook |

### Lưu ý Top Count

`Top Count = 100` chỉ an toàn khi số row tạo trong 26 giờ nhỏ hơn 100. Trong lúc test, Flow 1 có thể được gọi nhiều lần và tạo nhiều row. Nếu có hơn 100 row mới hơn row cần tìm, `timesheet_misa` có thể bị đẩy ra ngoài kết quả.

Khi debug:

- Tạm bỏ Filter Query để xác nhận list và field mapping trước.
- Có thể tăng Top Count nếu danh sách có nhiều test row.
- Kiểm tra raw output thay vì chỉ nhìn row trong SharePoint UI.

## 6. Khởi tạo các biến

### ExpectedSites

Type:

```text
Array
```

Dữ liệu kiểm thử hiện tại:

```json
[
  "timesheet_misa",
  "site_khong_ton_tai"
]
```

Không đưa `site_khong_ton_tai` vào cấu hình production. Đây chỉ là site giả để chứng minh dead-man switch phát hiện site thiếu backup.

Khi đưa vào production, `ExpectedSites` phải chứa toàn bộ site thực tế trong:

```text
/opt/mbc-backup/sites.conf
```

Tài liệu cũ liệt kê 9 site mẫu, nhưng production hiện có khoảng 12 site. Không copy danh sách 9 site cũ vào flow mà không đối chiếu inventory thực tế.

Danh sách mẫu cũ chỉ để tham khảo:

```json
[
  "marketplace_misa",
  "skuapp",
  "misa_sync_engine",
  "mbc360",
  "mbc_tool_ads",
  "powerapp_sku",
  "timesheet_misa",
  "mbc_ocr",
  "product_database"
]
```

### MissingSites

Type:

```text
Array
```

Initial value:

```json
[]
```

`MissingSites` phải bắt đầu bằng array rỗng, không phải chuỗi ký tự `"[]"`.

## 7. Vòng lặp `For each expected site`

Input của vòng lặp:

```text
variables('ExpectedSites')
```

Với dữ liệu test hiện tại, việc Power Automate hiển thị hai iteration là hoàn toàn đúng:

```text
Iteration 1: timesheet_misa
Iteration 2: site_khong_ton_tai
```

Mỗi iteration đại diện cho một site cần kiểm tra. Trong mỗi iteration, `Filter success rows` phải duyệt toàn bộ rows do `Get items` trả về và tìm row có:

```text
Site = site đang được kiểm tra
Status = success
```

### Concurrency

Bật Concurrency Control và đặt Degree of Parallelism bằng `1` nếu vòng lặp cập nhật chung biến array `MissingSites`. Việc append song song vào cùng một Array variable có thể gây kết quả không ổn định.

## 8. Điểm dễ nhầm nhất: có hai loại `Current item`

Đây là nguyên nhân có khả năng cao nhất khiến `Filter success rows` không tìm được `timesheet_misa` dù row đã tồn tại.

### Current item của vòng lặp ngoài

Expression:

```text
items('For_each_expected_site')
```

Giá trị lần lượt là chuỗi:

```text
timesheet_misa
site_khong_ton_tai
```

### Current item của Filter Array

Expression:

```text
item()
```

Đây là từng row SharePoint đang được `Filter success rows` đánh giá. Ví dụ:

```json
{
  "Title": "20260805_0233",
  "Site": {
    "Value": "timesheet_misa"
  },
  "Status": {
    "Value": "success"
  }
}
```

Tùy SharePoint connector, `Site` và `Status` cũng có thể được trả thẳng dưới dạng string:

```json
{
  "Title": "20260805_0233",
  "Site": "timesheet_misa",
  "Status": "success"
}
```

### Lỗi scope thường gặp

Nếu chọn một token Dynamic content có nhãn chung là `Current item`, New Designer có thể tạo expression `item()` thay vì `items('For_each_expected_site')`.

Phép so sánh khi đó về bản chất có thể thành:

```text
"timesheet_misa" = toàn bộ SharePoint row
```

Phép so sánh luôn False, `Filter success rows` trả `[]`, Condition `length(...) = 0` thành True và cả hai expected site đều bị append.

Để tránh hoàn toàn sự mơ hồ, dùng expression rõ ràng thay vì token `Current item` chung chung.

## 9. Cấu hình `Filter success rows`

From:

```text
body('Get_items')?['value']
```

Không dùng inline `filter()` trong Condition. Power Automate flow hiện tại dùng action `Filter array` riêng để dễ kiểm tra raw input/output và tương thích với New Designer.

### Trường hợp Choice trả về object có `Value`

Advanced mode:

```text
and(
  equals(
    item()?['Site']?['Value'],
    items('For_each_expected_site')
  ),
  equals(
    item()?['Status']?['Value'],
    'success'
  )
)
```

### Trường hợp Choice trả về string

Advanced mode:

```text
and(
  equals(
    item()?['Site'],
    items('For_each_expected_site')
  ),
  equals(
    item()?['Status'],
    'success'
  )
)
```

Không đoán kiểu dữ liệu. Kiểm tra `Get items` -> `Show raw outputs` -> `body` -> `value` để quyết định dùng phiên bản nào.

### Nếu dùng Basic mode

Cấu hình nhóm `And`:

| Vế trái | Operator | Vế phải |
|---|---|---|
| `Site Value` hoặc `Site` từ row của `Get items` | is equal to | expression `items('For_each_expected_site')` |
| `Status Value` hoặc `Status` từ row của `Get items` | is equal to | `success` |

Không chọn token `Current item` cho vế phải nếu không biết nó thuộc scope nào. Nhập trực tiếp bằng `fx`:

```text
items('For_each_expected_site')
```

## 10. Condition bên trong vòng lặp

Condition đúng:

```text
length(body('Filter_success_rows')) = 0
```

Code view đã từng được xác nhận đúng ở dạng:

```json
{
  "equals": [
    "@length(body('Filter_success_rows'))",
    0
  ]
}
```

Chỉ giữ một dòng điều kiện. Nếu New Designer còn tạo một dòng trống kiểu:

```text
Choose a value is equal to Choose a value
```

thì xóa dòng trống đó.

Giá trị `0` nên là Number được nhập qua `fx`, không phải string `"0"`.

### Ý nghĩa hai nhánh

Nếu Filter tìm thấy ít nhất một row success:

```text
length > 0
Condition = False
Không append
```

Nếu Filter không tìm thấy row success:

```text
length = 0
Condition = True
Append site hiện tại vào MissingSites
```

## 11. Append vào `MissingSites`

Action này nằm trong nhánh True của Condition.

Variable:

```text
MissingSites
```

Value phải được nhập qua `fx`:

```text
items('For_each_expected_site')
```

Không dùng token `Current item` chung chung. Dùng expression rõ ràng bảo đảm giá trị append là expected site của vòng lặp ngoài, không phải row SharePoint của Filter Array.

`Append` không phải nguyên nhân gốc khi cả hai site cùng bị thêm. Nó chỉ thực hiện đúng nhánh True. Nguyên nhân nằm ở việc `Filter success rows` trả array rỗng cho cả hai iteration.

## 12. Cách xác định chính xác lỗi hiện tại

Không thể kết luận từ giao diện cấu hình rằng `Get items` có thực sự trả row hay không. Phải xem run history.

### Bước 1: kiểm tra Get items

Mở lần chạy Flow 2 gần nhất:

```text
Get items -> Show raw outputs
```

Tìm:

```text
body.value
```

Xác nhận:

- `body.value` không phải array rỗng.
- Có row `Title = 20260805_0233` hoặc row success mới hơn.
- Row có `Site = timesheet_misa`.
- Row có `Status = success`.
- Ghi nhận `Site` và `Status` là string hay object có thuộc tính `Value`.

Có thể thêm Compose tạm thời ngay sau `Get items`:

```text
Name: Debug_get_items_count
Inputs: length(body('Get_items')?['value'])
```

Và:

```text
Name: Debug_get_items_data
Inputs: body('Get_items')?['value']
```

### Bước 2: kiểm tra iteration `timesheet_misa`

Mở:

```text
For each expected site
  Iteration timesheet_misa
    Filter success rows
      Show raw inputs
      Show raw outputs
```

Kiểm tra trường `from` trong raw inputs.

#### Trường hợp A: `from` là array rỗng

```json
{
  "from": []
}
```

Nguyên nhân nằm ở `Get items`, không nằm ở Condition hoặc Append. Kiểm tra:

- Đúng SharePoint site chưa.
- Đúng list `DB_Backup_Log` chưa.
- Filter Query 26 giờ có loại nhầm row không.
- Top Count có làm row cần tìm bị loại không.
- Row có thực sự nằm trong cửa sổ thời gian không.

Tạm xóa Filter Query và chạy lại để cô lập lỗi.

#### Trường hợp B: `from` có row nhưng output là array rỗng

```json
[]
```

Nguyên nhân nằm ở expression của `Filter success rows`. Kiểm tra:

- Vế phải có đúng là `items('For_each_expected_site')` không.
- Có dùng nhầm `item()` cho vế phải không.
- `Site` phải dùng `Site` hay `Site.Value`.
- `Status` phải dùng `Status` hay `Status.Value`.
- Giá trị thực tế có đúng chính tả `timesheet_misa` và `success` không.
- Có khoảng trắng hoặc newline ngoài ý muốn không.

#### Trường hợp C: Filter output có row nhưng Condition vẫn True

Nguyên nhân nằm ở Condition. Kiểm tra Code view và bảo đảm Condition chỉ có:

```text
length(body('Filter_success_rows')) = 0
```

Không để dòng điều kiện trống và không dùng output của action khác.

## 13. Logic đúng của test hiện tại

### Iteration 1: `timesheet_misa`

```text
Outer current item: timesheet_misa
Get items: có row timesheet_misa/success
Filter success rows: trả ít nhất 1 row
length(Filter success rows): lớn hơn 0
Condition length = 0: False
Không append
```

### Iteration 2: `site_khong_ton_tai`

```text
Outer current item: site_khong_ton_tai
Get items: không có row success tương ứng
Filter success rows: []
length(Filter success rows): 0
Condition length = 0: True
Append site_khong_ton_tai
```

### Kết quả bắt buộc

```json
[
  "site_khong_ton_tai"
]
```

## 14. Condition cảnh báo sau vòng lặp

Action này phải nằm ngoài `For each expected site`.

Expression:

```text
length(variables('MissingSites'))
```

Operator:

```text
is greater than
```

Giá trị Number:

```text
0
```

Nếu True, gửi cả Teams mention và email High importance.

Teams message mẫu:

```text
[MISSING BACKUP] Không có backup thành công trong 26 giờ gần nhất

Sites không có backup thành công:
@{join(variables('MissingSites'), ', ')}

Kiểm tra theo thứ tự:
1. VPS có đang hoạt động không?
2. systemctl list-timers mbc-backup.timer
3. journalctl -u mbc-backup -n 200
4. FLOW_WEBHOOK_URL còn hợp lệ không?

Runbook: /opt/mbc-backup/runbook.md
```

Email subject:

```text
[MISSING BACKUP] @{join(variables('MissingSites'), ', ')}
```

## 15. Giới hạn thiết kế

- Flow 2 có thể phát hiện không có row success, nhưng không tự phân biệt được backup không chạy với backup đã chạy nhưng webhook Flow 1 không gửi được.
- Khi có cảnh báo, phải kiểm tra cả VPS, systemd timer, journal và webhook.
- Flow 2 phụ thuộc vào Power Automate, SharePoint và tenant Microsoft 365. Nếu toàn bộ tenant gặp sự cố, Flow 2 cũng không hoạt động.
- `ExpectedSites` hard-code trong flow có nguy cơ lệch với `/opt/mbc-backup/sites.conf`. Về lâu dài nên đưa inventory vào một SharePoint list riêng hoặc nguồn cấu hình trung tâm.
- Chỉ một row `success` mới chứng minh site có backup thành công. Row `failed` hoặc `fatal` không được làm Filter trả match.

## 16. Checklist nghiệm thu Flow 2

- [ ] Flow 1 vẫn hoạt động và tiếp tục ghi row vào `DB_Backup_Log`.
- [ ] `Get items` trả các row trong 26 giờ gần nhất.
- [ ] Raw output xác nhận đúng cấu trúc `Site` và `Status`.
- [ ] `timesheet_misa` có row `success` và không bị append.
- [ ] `site_khong_ton_tai` không có row success và bị append.
- [ ] Kết quả test của `MissingSites` chỉ là `site_khong_ton_tai`.
- [ ] Vòng lặp dùng concurrency degree `1`.
- [ ] Append dùng `items('For_each_expected_site')`, không dùng token Current item mơ hồ.
- [ ] Condition bên trong vòng lặp chỉ có `length(body('Filter_success_rows')) = 0`.
- [ ] Condition cảnh báo nằm ngoài vòng lặp.
- [ ] Teams mention được gửi khi `MissingSites` không rỗng.
- [ ] Email High importance được gửi khi `MissingSites` không rỗng.
- [ ] Không gửi cảnh báo khi tất cả site production có row success.
- [ ] `ExpectedSites` production đã được đối chiếu với `/opt/mbc-backup/sites.conf`.
- [ ] Đã bỏ `site_khong_ton_tai` khỏi cấu hình production sau khi test.

## 17. Thứ tự công việc tiếp theo cho người tiếp quản

1. Không debug lại Flow 1; Flow 1 đã hoạt động.
2. Chạy Flow 2 với `ExpectedSites = ["timesheet_misa", "site_khong_ton_tai"]`.
3. Mở run history và kiểm tra raw output của `Get items`.
4. Nếu `Get items` rỗng, tạm bỏ Filter Query 26 giờ rồi chạy lại.
5. Nếu `Get items` có row, kiểm tra raw input/output của `Filter_success_rows` tại iteration `timesheet_misa`.
6. Xác định Choice fields là string hay object có `Value` rồi dùng expression tương ứng.
7. Bảo đảm vế expected site là `items('For_each_expected_site')`, không phải `item()`.
8. Bảo đảm Append cũng dùng `items('For_each_expected_site')`.
9. Xóa dòng trống còn thừa trong Condition nếu có.
10. Chạy lại cho đến khi `MissingSites` chỉ còn `site_khong_ton_tai`.
11. Hoàn thiện Teams mention và email High importance ở Condition ngoài vòng lặp.
12. Thay test array bằng toàn bộ site production từ `/opt/mbc-backup/sites.conf`.

## 18. Thông tin hệ thống liên quan

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

Các field Flow 2 sử dụng trong `DB_Backup_Log`:

```text
Title
Site
Status
Created
```

Các giá trị Status hợp lệ:

```text
success
failed
fatal
```

Flow 2 phải tìm `success` chính xác, không chỉ kiểm tra sự tồn tại của bất kỳ row nào.
