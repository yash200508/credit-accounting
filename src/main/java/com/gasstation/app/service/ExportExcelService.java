package com.gasstation.app.service;

import com.gasstation.app.dao.CustomerDao;
import com.gasstation.app.dao.TransactionDao;
import com.gasstation.app.model.Customer;
import com.gasstation.app.model.Transaction;

import org.apache.poi.ss.usermodel.Row;
import org.apache.poi.ss.usermodel.Sheet;
import org.apache.poi.ss.usermodel.Workbook;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;

import java.io.File;
import java.io.FileOutputStream;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

public class ExportExcelService {

    private final CustomerDao customerDao;
    private final TransactionDao txnDao;

    public ExportExcelService() {
        this.customerDao = new CustomerDao();
        this.txnDao = new TransactionDao();
    }

    public ExportExcelService(CustomerDao customerDao, TransactionDao txnDao) {
        this.customerDao = customerDao;
        this.txnDao = txnDao;
    }

    /**
     * Exports:
     * Sheet 1: Customers
     * Sheet 2: Transactions (VOID excluded if TransactionDao.listAllPosted() excludes VOID)
     */
    public void exportAllToXlsx(File outFile) throws Exception {
        if (outFile == null) throw new IllegalArgumentException("Output file is null");

        List<Customer> customers = customerDao.listAll();
        List<Transaction> txns = txnDao.listAllPosted(); // ✅ VOID excluded

        // Map customer_id -> Customer for joining name/phone into txn sheet
        Map<Long, Customer> custMap = new HashMap<>();
        for (Customer c : customers) {
            custMap.put(c.getCustomerId(), c);
        }

        try (Workbook wb = new XSSFWorkbook()) {

            // ---------------- Sheet 1: Customers ----------------
            Sheet s1 = wb.createSheet("Customers");
            int r = 0;

            Row h = s1.createRow(r++);
            int c = 0;
            h.createCell(c++).setCellValue("customer_id");
            h.createCell(c++).setCellValue("name");
            h.createCell(c++).setCellValue("phone");
            h.createCell(c++).setCellValue("address");
            h.createCell(c++).setCellValue("notes");
            h.createCell(c++).setCellValue("is_active");
            h.createCell(c++).setCellValue("credit_limit_paise");
            h.createCell(c++).setCellValue("due_days");
            h.createCell(c++).setCellValue("grace_days");
            h.createCell(c++).setCellValue("risk_score");
            h.createCell(c++).setCellValue("risk_level");
            h.createCell(c++).setCellValue("next_followup_date");
            h.createCell(c++).setCellValue("followup_notes");

            for (Customer cu : customers) {
                Row row = s1.createRow(r++);
                int k = 0;
                row.createCell(k++).setCellValue(cu.getCustomerId());
                row.createCell(k++).setCellValue(nvl(cu.getName()));
                row.createCell(k++).setCellValue(nvl(cu.getPhone()));
                row.createCell(k++).setCellValue(nvl(cu.getAddress()));
                row.createCell(k++).setCellValue(nvl(cu.getNotes()));
                row.createCell(k++).setCellValue(cu.getIsActive());
                row.createCell(k++).setCellValue(cu.getCreditLimitPaise());
                row.createCell(k++).setCellValue(cu.getDueDays());
                row.createCell(k++).setCellValue(cu.getGraceDays());
                row.createCell(k++).setCellValue(cu.getRiskScore());
                row.createCell(k++).setCellValue(nvl(cu.getRiskLevel()));
                row.createCell(k++).setCellValue(nvl(cu.getNextFollowupDate()));
                row.createCell(k++).setCellValue(nvl(cu.getFollowupNotes()));
            }

            // autosize a bit (optional)
            for (int i = 0; i <= 6; i++) s1.autoSizeColumn(i);

            // ---------------- Sheet 2: Transactions ----------------
            Sheet s2 = wb.createSheet("Transactions");
            int tr = 0;

            Row th = s2.createRow(tr++);
            int tcol = 0;
            th.createCell(tcol++).setCellValue("txn_id");
            th.createCell(tcol++).setCellValue("customer_id");
            th.createCell(tcol++).setCellValue("customer_name");
            th.createCell(tcol++).setCellValue("customer_phone");
            th.createCell(tcol++).setCellValue("txn_date");
            th.createCell(tcol++).setCellValue("txn_type");
            th.createCell(tcol++).setCellValue("amount_paise");
            th.createCell(tcol++).setCellValue("reference");
            th.createCell(tcol++).setCellValue("notes");
            th.createCell(tcol++).setCellValue("status");
            th.createCell(tcol++).setCellValue("void_reason");
            th.createCell(tcol++).setCellValue("voided_at");

            for (Transaction t : txns) {
                Customer cu = custMap.get(t.getCustomerId());

                Row row = s2.createRow(tr++);
                int k = 0;
                row.createCell(k++).setCellValue(t.getTxnId());
                row.createCell(k++).setCellValue(t.getCustomerId());
                row.createCell(k++).setCellValue(cu == null ? "" : nvl(cu.getName()));
                row.createCell(k++).setCellValue(cu == null ? "" : nvl(cu.getPhone()));
                row.createCell(k++).setCellValue(nvl(t.getTxnDate()));
                row.createCell(k++).setCellValue(nvl(t.getTxnType()));
                row.createCell(k++).setCellValue(t.getAmountPaise());
                row.createCell(k++).setCellValue(nvl(t.getReference()));
                row.createCell(k++).setCellValue(nvl(t.getNotes()));
                row.createCell(k++).setCellValue(nvl(t.getStatus()));
                row.createCell(k++).setCellValue(nvl(t.getVoidReason()));
                row.createCell(k++).setCellValue(nvl(t.getVoidedAt()));
            }

            for (int i = 0; i <= 6; i++) s2.autoSizeColumn(i);

            // ---------------- Write file ----------------
            try (FileOutputStream fos = new FileOutputStream(outFile)) {
                wb.write(fos);
            }
        } catch (Exception e) {
            throw new RuntimeException("Export failed: " + e.getMessage(), e);
        }
    }

    private String nvl(String s) {
        return s == null ? "" : s;
    }
}
