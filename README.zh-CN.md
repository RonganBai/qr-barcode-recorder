# qr-barcode-recorder

基于 Flutter 的安卓扫码记录工具，支持二维码/条码识别、自动分表、备注与 Excel 导出。

English README: [README.md](README.md)

## 功能

- 扫描 QR 和常见一维码
- 按逐位字符结构自动分表（`A`/`N`/`S`）
- 每个表独立计数与步长提醒
- 备注可编辑，带备注行高亮
- 支持按住扫描、暂停/继续、闪光灯、搜索
- 可选择表格导出 Excel，并自定义文件名

## 运行

```bash
flutter pub get
flutter run
```

## 导出

- 可选择一个或多个表导出
- Excel 单元格文本居中
- 含备注的行会标黄
