package com.gasstation.app;

import com.gasstation.app.dao.CustomerDao;
import com.gasstation.app.dao.TransactionDao;
import com.gasstation.app.model.Customer;
import com.gasstation.app.model.Transaction;
import com.gasstation.app.service.TransactionImportValidator;
import com.gasstation.app.util.MoneyUtil;

import javafx.beans.property.SimpleStringProperty;
import javafx.collections.FXCollections;
import javafx.collections.ObservableList;
import javafx.geometry.Insets;
import javafx.scene.control.*;
import javafx.scene.layout.*;
import javafx.stage.FileChooser;

import org.apache.poi.ss.usermodel.*;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;

import java.time.LocalDate;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;

import java.util.*;

public class ImportExcelScreen extends BorderPane {

    private final AppNavigator nav;

    private final Label fileLabel = new Label("No file selected");
    private final Button backBtn = new Button("← Back");
    private final Button chooseBtn = new Button("Choose Excel File (.xlsx)");
    private final Button importBtn = new Button("Import");
    private final TextArea logArea = new TextArea();

    private final TableView<Map<String, String>> previewTable = new TableView<>();
    private final ObservableList<Map<String, String>> previewData = FXCollections.observableArrayList();

    private File selectedFile;

    private final CustomerDao customerDao = new CustomerDao();
    private final TransactionDao txnDao = new TransactionDao();

    public ImportExcelScreen(AppNavigator nav) {
        this.nav = nav;

        setPadding(new Insets(12));

        importBtn.setDisable(true);
        logArea.setEditable(false);
        logArea.setWrapText(true);
        logArea.setPrefRowCount(10);

        previewTable.setItems(previewData);
        previewTable.setPlaceholder(new Label("Preview will appear here after selecting a file."));

        setTop(buildTop());
        setCenter(buildCenter());
        setBottom(buildBottom());

        chooseBtn.setOnAction(e -> chooseFile());
        importBtn.setOnAction(e -> importFile());

        backBtn.setOnAction(e -> this.nav.goBack());
    }

    private Pane buildTop() {
        Label title = new Label("Import Excel (Google Form Export)");
        title.setStyle("-fx-font-size: 16px; -fx-font-weight: bold;");

        Label help = new Label("""
                Required columns (header row): Phone, Date, Type, Amount OR AmountPaise
                Optional: Reference, Notes
                Type must be DEBIT or CREDIT (or 'Payment' / 'Credit Taken').
                """.trim());

        HBox row = new HBox(10, backBtn, chooseBtn, importBtn);

        VBox box = new VBox(8, title, help, fileLabel, row);
        box.setPadding(new Insets(0, 0, 12, 0));
        return box;
    }

    private Pane buildCenter() {
        VBox box = new VBox(8, new Label("Preview (first 10 rows)"), previewTable);
        VBox.setVgrow(previewTable, Priority.ALWAYS);
        return box;
    }

    private Pane buildBottom() {
        VBox box = new VBox(8, new Label("Import Log"), logArea);
        box.setPadding(new Insets(12, 0, 0, 0));
        return box;
    }

    private void chooseFile() {
        FileChooser fc = new FileChooser();
        fc.setTitle("Select Excel file");
        fc.getExtensionFilters().add(new FileChooser.ExtensionFilter("Excel Files", "*.xlsx"));

        File f = fc.showOpenDialog(getScene() == null ? null : getScene().getWindow());
        if (f == null) return;

        selectedFile = f;
        fileLabel.setText("Selected: " + f.getAbsolutePath());

        logArea.clear();
        log("Selected file: " + f.getName());

        try {
            List<Map<String, String>> rows = readRows(f, 10);
            buildPreviewColumns(rows);
            previewData.setAll(rows);

            Set<String> keys = rows.isEmpty() ? Set.of() : rows.get(0).keySet();
            boolean hasAmount = keys.contains("Amount") || keys.contains("AmountPaise");

            if (!keys.contains("Phone") || !keys.contains("Date") || !keys.contains("Type") || !hasAmount) {
                log("⚠ Missing required headers. Found headers: " + keys);
                importBtn.setDisable(true);
                return;
            }

            importBtn.setDisable(false);
            log("Preview loaded. Ready to import.");
        } catch (Exception ex) {
            importBtn.setDisable(true);
            previewData.clear();
            previewTable.getColumns().clear();
            log("ERROR reading file: " + ex.getMessage());
            ex.printStackTrace();
        }
    }

    private void importFile() {
        if (selectedFile == null) return;

        int imported = 0;
        int skipped = 0;

        // ✅ Collect rows that fail import (will be exported to new excel)
        List<Map<String, String>> failedRows = new ArrayList<>();

        try {
            List<Map<String, String>> allRows = readRows(selectedFile, Integer.MAX_VALUE);
            if (allRows.isEmpty()) {
                log("No data rows found.");
                return;
            }

            Map<String, Customer> phoneMap = buildPhoneMap();

            for (int i = 0; i < allRows.size(); i++) {
                Map<String, String> r = allRows.get(i);

                String phone = normalizePhoneForLookup(r.getOrDefault("Phone", ""));
                String dateStr = safe(r.getOrDefault("Date", ""));
                String typeStr = safe(r.getOrDefault("Type", ""));

                String amountStr = safe(r.getOrDefault("Amount", ""));           // rupees
                String amountPaiseStr = safe(r.getOrDefault("AmountPaise", "")); // paise

                // required fields
                if (!TransactionImportValidator.hasRequiredFields(phone, dateStr, typeStr, amountStr, amountPaiseStr)) {

                    skipped++;
                    log("SKIP row " + (i + 2) + ": missing required fields");
                    failedRows.add(withFailReason(r, "Missing required fields"));
                    continue;
                }

                // customer lookup
                Customer c = phoneMap.get(phone);
                if (c == null) {
                    skipped++;
                    log("SKIP row " + (i + 2) + ": phone not found in customers: " + phone);
                    failedRows.add(withFailReason(r, "Phone not found in customers: " + phone));
                    continue;
                }

                // normalize type
                String normalizedType = normalizeType(typeStr);
                if (normalizedType == null) {
                    skipped++;
                    log("SKIP row " + (i + 2) + ": invalid Type: " + typeStr);
                    failedRows.add(withFailReason(r, "Invalid Type: " + typeStr));
                    continue;
                }

                // parse date
                LocalDate date = parseDate(dateStr);
                if (date == null) {
                    skipped++;
                    log("SKIP row " + (i + 2) + ": invalid Date: " + dateStr);
                    failedRows.add(withFailReason(r, "Invalid Date: " + dateStr));
                    continue;
                }

                // parse amount
                long paise = (!amountPaiseStr.isEmpty())
                        ? parseLongSafe(amountPaiseStr)
                        : parseRupeesToPaise(amountStr);

                if (paise <= 0) {
                    skipped++;
                    log("SKIP row " + (i + 2) + ": invalid Amount: " +
                            (!amountPaiseStr.isEmpty() ? amountPaiseStr : amountStr));
                    failedRows.add(withFailReason(r, "Invalid Amount"));
                    continue;
                }

                // insert transaction
                Transaction t = new Transaction();
                t.setCustomerId(c.getCustomerId());
                t.setTxnDate(date.toString());
                t.setTxnType(normalizedType);
                t.setAmountPaise(paise);
                t.setReference(safe(r.getOrDefault("Reference", "")));
                t.setNotes(safe(r.getOrDefault("Notes", "")));

                txnDao.insert(t);
                imported++;
            }

            log("DONE ✅ Imported=" + imported + " | Skipped=" + skipped);

            // ✅ export failures to a new excel
            if (!failedRows.isEmpty()) {
                writeFailedRowsExcel(failedRows);
            }

        } catch (Exception ex) {
            log("ERROR importing: " + ex.getMessage());
            ex.printStackTrace();
        }
    }

    private Map<String, String> withFailReason(Map<String, String> row, String reason) {
        Map<String, String> out = new LinkedHashMap<>(row);
        out.put("FAIL_REASON", reason);
        return out;
    }

    private void writeFailedRowsExcel(List<Map<String, String>> failedRows) {
        if (failedRows.isEmpty() || selectedFile == null) return;

        try (Workbook wb = new XSSFWorkbook()) {
            Sheet sheet = wb.createSheet("NOT_IMPORTED");

            // headers (keep stable)
            LinkedHashSet<String> headerSet = new LinkedHashSet<>();
            for (Map<String, String> row : failedRows) headerSet.addAll(row.keySet());

            List<String> headers = new ArrayList<>(headerSet);

            Row headerRow = sheet.createRow(0);
            for (int i = 0; i < headers.size(); i++) {
                headerRow.createCell(i).setCellValue(headers.get(i));
            }

            int r = 1;
            for (Map<String, String> row : failedRows) {
                Row excelRow = sheet.createRow(r++);
                for (int c = 0; c < headers.size(); c++) {
                    String h = headers.get(c);
                    excelRow.createCell(c).setCellValue(row.getOrDefault(h, ""));
                }
            }

            for (int i = 0; i < headers.size(); i++) {
                sheet.autoSizeColumn(i);
            }

            File out = new File(
                    selectedFile.getParentFile(),
                    selectedFile.getName().replace(".xlsx", "") + "_NOT_IMPORTED.xlsx"
            );

            try (FileOutputStream fos = new FileOutputStream(out)) {
                wb.write(fos);
            }

            log("⚠ Skipped rows exported to: " + out.getAbsolutePath());

        } catch (Exception e) {
            log("ERROR writing skipped rows Excel: " + e.getMessage());
            e.printStackTrace();
        }
    }

    // ---------------- Excel reading ----------------

    private List<Map<String, String>> readRows(File file, int limit) throws Exception {
        List<Map<String, String>> rows = new ArrayList<>();

        try (FileInputStream fis = new FileInputStream(file);
             Workbook wb = WorkbookFactory.create(fis)) {

            Sheet sheet = findBestSheet(wb);
            if (sheet == null) return rows;

            Iterator<Row> it = sheet.rowIterator();
            if (!it.hasNext()) return rows;

            Row headerRow = it.next();
            List<String> headers = readHeaderCells(headerRow);

            int count = 0;
            while (it.hasNext() && count < limit) {
                Row r = it.next();
                Map<String, String> raw = new LinkedHashMap<>();

                for (int i = 0; i < headers.size(); i++) {
                    org.apache.poi.ss.usermodel.Cell cell =
                            r.getCell(i, Row.MissingCellPolicy.RETURN_BLANK_AS_NULL);

                    String header = headers.get(i);
                    String value = (cell == null) ? "" : getCellString(cell);
                    raw.put(header, value);
                }

                Map<String, String> normalized = normalizeKeys(raw);
                rows.add(normalized);
                count++;
            }
        }

        return rows;
    }

    private List<String> readHeaderCells(Row headerRow) {
        List<String> headers = new ArrayList<>();
        short last = headerRow.getLastCellNum();

        for (int i = 0; i < last; i++) {
            org.apache.poi.ss.usermodel.Cell cell =
                    headerRow.getCell(i, Row.MissingCellPolicy.RETURN_BLANK_AS_NULL);

            String value = (cell == null) ? "" : getCellString(cell);
            headers.add(value == null ? "" : value.trim());
        }

        return headers;
    }

    private Sheet findBestSheet(Workbook wb) {
        for (int s = 0; s < wb.getNumberOfSheets(); s++) {
            Sheet sheet = wb.getSheetAt(s);
            Row headerRow = sheet.getRow(sheet.getFirstRowNum());
            if (headerRow == null) continue;

            List<String> headers = readHeaderCells(headerRow);
            Map<String, String> raw = new LinkedHashMap<>();
            for (String h : headers) raw.put(h, "x");

            Map<String, String> norm = normalizeKeys(raw);

            boolean hasPhone = norm.containsKey("Phone");
            boolean hasDate = norm.containsKey("Date");
            boolean hasType = norm.containsKey("Type");
            boolean hasAmount = norm.containsKey("Amount") || norm.containsKey("AmountPaise");

            if (hasPhone && hasDate && hasType && hasAmount) {
                return sheet;
            }
        }

        return wb.getNumberOfSheets() > 0 ? wb.getSheetAt(0) : null;
    }

    private Map<String, String> normalizeKeys(Map<String, String> raw) {
        Map<String, String> out = new LinkedHashMap<>();

        for (Map.Entry<String, String> e : raw.entrySet()) {
            String k = e.getKey() == null ? "" : e.getKey().trim();
            String v = e.getValue() == null ? "" : e.getValue().trim();

            String kk = k.toLowerCase().trim();

            if (kk.equals("customer_phone") || kk.equals("customer phone") || kk.equals("phone") || kk.equals("phone number") || kk.equals("mobile")) k = "Phone";
            else if (kk.equals("txn_date") || kk.equals("transaction_date") || kk.equals("transaction date") || kk.equals("date")) k = "Date";
            else if (kk.equals("type") || kk.equals("transaction type") || kk.equals("txn type")) k = "Type";

            else if (kk.equals("amount_paise") || kk.equals("amount paise")) k = "AmountPaise";
            else if (kk.equals("amount") || kk.equals("amount (₹)") || kk.equals("amount (rs)") || kk.equals("rupees")) k = "Amount";

            else if (kk.equals("reference") || kk.equals("ref")) k = "Reference";
            else if (kk.equals("notes") || kk.equals("note") || kk.equals("remarks") || kk.equals("remark")) k = "Notes";

            out.put(k, v);
        }

        out.putIfAbsent("Phone", "");
        out.putIfAbsent("Date", "");
        out.putIfAbsent("Type", "");
        out.putIfAbsent("Amount", "");
        out.putIfAbsent("AmountPaise", "");
        out.putIfAbsent("Reference", "");
        out.putIfAbsent("Notes", "");

        return out;
    }

    private void buildPreviewColumns(List<Map<String, String>> rows) {
        previewTable.getColumns().clear();
        if (rows.isEmpty()) return;

        for (String key : rows.get(0).keySet()) {
            TableColumn<Map<String, String>, String> col = new TableColumn<>(key);
            col.setCellValueFactory(data -> new SimpleStringProperty(data.getValue().getOrDefault(key, "")));
            col.setPrefWidth(150);
            previewTable.getColumns().add(col);
        }
    }

    private String getCellString(org.apache.poi.ss.usermodel.Cell cell) {
        if (cell == null) return "";

        CellType type = cell.getCellType();
        if (type == CellType.FORMULA) type = cell.getCachedFormulaResultType();

        switch (type) {
            case STRING:
                return cell.getStringCellValue();

            case NUMERIC:
                if (DateUtil.isCellDateFormatted(cell)) {
                    try {
                        LocalDate d = cell.getLocalDateTimeCellValue().toLocalDate();
                        return d.toString();
                    } catch (Exception ignored) {}
                }
                double n = cell.getNumericCellValue();
                if (Math.floor(n) == n) return String.valueOf((long) n);
                return String.valueOf(n);

            case BOOLEAN:
                return String.valueOf(cell.getBooleanCellValue());

            case BLANK:
            default:
                return "";
        }
    }

    // ---------------- Parsing & helpers ----------------

    private Map<String, Customer> buildPhoneMap() throws Exception {
        Map<String, Customer> map = new HashMap<>();
        List<Customer> all = customerDao.listAll();
        for (Customer c : all) {
            String p = normalizePhoneForLookup(c.getPhone());
            if (!p.isEmpty()) map.put(p, c);
        }
        return map;
    }

    private String normalizeType(String type) {
        return TransactionImportValidator.normalizeType(type);
    }

    private LocalDate parseDate(String s) {
        String t = safe(s);
        if (t.isEmpty()) return null;

        List<DateTimeFormatter> fmts = List.of(
                DateTimeFormatter.ISO_LOCAL_DATE,
                DateTimeFormatter.ofPattern("d/M/yyyy"),
                DateTimeFormatter.ofPattern("dd/MM/yyyy"),
                DateTimeFormatter.ofPattern("d-M-yyyy"),
                DateTimeFormatter.ofPattern("dd-MM-yyyy")
        );

        for (DateTimeFormatter f : fmts) {
            try {
                return LocalDate.parse(t, f);
            } catch (Exception ignored) {}
        }

        try {
            double v = Double.parseDouble(t);
            Date d = DateUtil.getJavaDate(v);
            return d.toInstant().atZone(ZoneId.systemDefault()).toLocalDate();
        } catch (Exception ignored) {}

        return null;
    }

    private long parseRupeesToPaise(String text) {
        String t = safe(text);
        if (t.isEmpty()) return 0;

        t = t.replace("Rs.", "")
                .replace("rs.", "")
                .replace("Rs", "")
                .replace("rs", "")
                .trim();

        try {
            return MoneyUtil.parseMoneyToPaise(t);
        } catch (IllegalArgumentException | ArithmeticException e) {
            return 0;
        }
    }

    private String normalizePhoneForLookup(String s) {
        String d = digitsOnly(s);
        if (d.length() < 10) return "";
        if (d.length() > 10) d = d.substring(d.length() - 10);
        return d;
    }

    private String digitsOnly(String s) {
        return s == null ? "" : s.replaceAll("\\D+", "");
    }

    private String safe(String s) {
        return s == null ? "" : s.trim();
    }

    private void log(String msg) {
        logArea.appendText(msg + "\n");
    }

    private long parseLongSafe(String s) {
        try {
            if (s == null) return 0;
            String d = s.replaceAll("\\D+", "");
            if (d.isEmpty()) return 0;
            return Long.parseLong(d);
        } catch (Exception e) {
            return 0;
        }
    }
}
