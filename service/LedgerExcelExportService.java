package com.gasstation.app.service;

import com.gasstation.app.dao.CustomerDao;
import com.gasstation.app.dao.TransactionDao;
import com.gasstation.app.model.Customer;
import com.gasstation.app.model.Transaction;
import org.apache.poi.common.usermodel.HyperlinkType;
import org.apache.poi.ss.usermodel.*;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;

import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.SQLException;
import java.time.LocalDate;
import java.util.*;

public class LedgerExcelExportService {

    private final CustomerDao customerDao = new CustomerDao();
    private final TransactionDao txnDao = new TransactionDao();

    public void exportAccountingXlsx(Path outFile, LocalDate from, LocalDate to) throws Exception {
        Objects.requireNonNull(outFile, "outFile");
        Objects.requireNonNull(from, "from");
        Objects.requireNonNull(to, "to");

        List<Customer> customers = customerDao.listAll();
        List<Transaction> allTxns = txnDao.listAllPosted(); // VOID excluded

        // Filter by date range inclusive
        List<Transaction> rangeTxns = new ArrayList<>();
        for (Transaction t : allTxns) {
            LocalDate d = LocalDate.parse(t.getTxnDate());
            if (!d.isBefore(from) && !d.isAfter(to)) {
                rangeTxns.add(t);
            }
        }

        // Group txns by customer_id
        Map<Long, List<Transaction>> byCustomer = new HashMap<>();
        for (Transaction t : rangeTxns) {
            byCustomer.computeIfAbsent(t.getCustomerId(), k -> new ArrayList<>()).add(t);
        }

        try (Workbook wb = new XSSFWorkbook()) {

            CellStyle headerStyle = makeHeaderStyle(wb);
            CreationHelper helper = wb.getCreationHelper();

            // ---------- Customers sheet ----------
            Sheet customersSheet = wb.createSheet("Customers");

            // header
            Row h = customersSheet.createRow(0);
            String[] cols = {"customer_id", "name", "phone", "address", "notes", "status"};
            for (int i = 0; i < cols.length; i++) {
                Cell c = h.createCell(i);
                c.setCellValue(cols[i]);
                c.setCellStyle(headerStyle);
            }

            // create per-customer sheets + map name->sheetName
            Map<Long, String> custSheetName = new HashMap<>();
            for (Customer c : customers) {
                String sheetName = safeSheetName(c.getName(), c.getCustomerId());
                // ensure uniqueness
                sheetName = uniqueSheetName(wb, sheetName);
                custSheetName.put(c.getCustomerId(), sheetName);

                Sheet s = wb.createSheet(sheetName);
                writeTxnSheet(s, headerStyle, byCustomer.getOrDefault(c.getCustomerId(), List.of()));
            }

            // fill customers rows with hyperlink on name
            int r = 1;
            for (Customer c : customers) {
                Row row = customersSheet.createRow(r++);

                row.createCell(0).setCellValue(c.getCustomerId());

                // name cell with hyperlink -> their sheet (only if sheet exists)
                Cell nameCell = row.createCell(1);
                nameCell.setCellValue(c.getName() == null ? "" : c.getName());

                String targetSheet = custSheetName.get(c.getCustomerId());
                if (targetSheet != null) {
                    Hyperlink link = helper.createHyperlink(HyperlinkType.DOCUMENT);
                    link.setAddress("'" + targetSheet + "'!A1");
                    nameCell.setHyperlink(link);

                    CellStyle linkStyle = makeLinkStyle(wb);
                    nameCell.setCellStyle(linkStyle);
                }

                row.createCell(2).setCellValue(c.getPhone() == null ? "" : c.getPhone());
                row.createCell(3).setCellValue(c.getAddress() == null ? "" : c.getAddress());
                row.createCell(4).setCellValue(c.getNotes() == null ? "" : c.getNotes());
                row.createCell(5).setCellValue(c.getIsActive() == 1 ? "ACTIVE" : "INACTIVE");
            }

            autosize(customersSheet, cols.length);

            // ---------- All_Transactions sheet ----------
            Sheet allSheet = wb.createSheet("All_Transactions");
            writeAllTransactionsSheet(allSheet, headerStyle, rangeTxns);
            autosize(allSheet, 7);

            // save
            try (OutputStream os = Files.newOutputStream(outFile)) {
                wb.write(os);
            }
        }
    }

    private void writeTxnSheet(Sheet sheet, CellStyle headerStyle, List<Transaction> txns) {
        Row h = sheet.createRow(0);
        String[] cols = {"txn_id", "txn_date", "txn_type", "amount_paise", "reference", "notes", "status"};
        for (int i = 0; i < cols.length; i++) {
            Cell c = h.createCell(i);
            c.setCellValue(cols[i]);
            c.setCellStyle(headerStyle);
        }

        int r = 1;
        for (Transaction t : txns) {
            Row row = sheet.createRow(r++);
            row.createCell(0).setCellValue(t.getTxnId());
            row.createCell(1).setCellValue(nullSafe(t.getTxnDate()));
            row.createCell(2).setCellValue(nullSafe(t.getTxnType()));
            row.createCell(3).setCellValue(t.getAmountPaise());
            row.createCell(4).setCellValue(nullSafe(t.getReference()));
            row.createCell(5).setCellValue(nullSafe(t.getNotes()));
            row.createCell(6).setCellValue(nullSafe(t.getStatus()));
        }

        autosize(sheet, cols.length);
    }

    private void writeAllTransactionsSheet(Sheet sheet, CellStyle headerStyle, List<Transaction> txns) throws SQLException {
        Row h = sheet.createRow(0);
        String[] cols = {"txn_id", "customer_id", "txn_date", "txn_type", "amount_paise", "reference", "notes"};
        for (int i = 0; i < cols.length; i++) {
            Cell c = h.createCell(i);
            c.setCellValue(cols[i]);
            c.setCellStyle(headerStyle);
        }

        int r = 1;
        for (Transaction t : txns) {
            Row row = sheet.createRow(r++);
            row.createCell(0).setCellValue(t.getTxnId());
            row.createCell(1).setCellValue(t.getCustomerId());
            row.createCell(2).setCellValue(nullSafe(t.getTxnDate()));
            row.createCell(3).setCellValue(nullSafe(t.getTxnType()));
            row.createCell(4).setCellValue(t.getAmountPaise());
            row.createCell(5).setCellValue(nullSafe(t.getReference()));
            row.createCell(6).setCellValue(nullSafe(t.getNotes()));
        }
    }

    private CellStyle makeHeaderStyle(Workbook wb) {
        Font f = wb.createFont();
        f.setBold(true);
        CellStyle cs = wb.createCellStyle();
        cs.setFont(f);
        return cs;
    }

    private CellStyle makeLinkStyle(Workbook wb) {
        Font f = wb.createFont();
        f.setUnderline(Font.U_SINGLE);
        f.setColor(IndexedColors.BLUE.getIndex());
        CellStyle cs = wb.createCellStyle();
        cs.setFont(f);
        return cs;
    }

    private void autosize(Sheet s, int cols) {
        for (int i = 0; i < cols; i++) s.autoSizeColumn(i);
    }

    private String nullSafe(String s) {
        return s == null ? "" : s;
    }

    private String safeSheetName(String name, long id) {
        String base = (name == null ? "" : name.trim());
        if (base.isEmpty()) base = "Customer_" + id;

        // remove invalid chars for Excel sheet
        base = base.replaceAll("[\\\\/?*\\[\\]:]", " ");
        base = base.replaceAll("\\s+", " ").trim();

        if (base.length() > 25) base = base.substring(0, 25).trim();
        if (base.isEmpty()) base = "Customer_" + id;

        return base;
    }

    private String uniqueSheetName(Workbook wb, String base) {
        String name = base;
        int i = 2;
        while (wb.getSheet(name) != null) {
            name = base;
            String suffix = "_" + i++;
            if (name.length() + suffix.length() > 31) {
                name = name.substring(0, 31 - suffix.length());
            }
            name = name + suffix;
        }
        // Excel max is 31 chars
        if (name.length() > 31) name = name.substring(0, 31);
        return name;
    }
}
