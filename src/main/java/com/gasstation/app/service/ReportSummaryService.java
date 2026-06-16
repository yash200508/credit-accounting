package com.gasstation.app.service;

import com.gasstation.app.dao.CustomerDao;
import com.gasstation.app.dao.TransactionDao;
import com.gasstation.app.model.Customer;

import java.sql.SQLException;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;

/** Non-UI report calculations used by report tests and future report screens. */
public class ReportSummaryService {
    private final CustomerDao customerDao;
    private final TransactionDao transactionDao;

    public ReportSummaryService() {
        this(new CustomerDao(), new TransactionDao());
    }

    public ReportSummaryService(CustomerDao customerDao, TransactionDao transactionDao) {
        this.customerDao = Objects.requireNonNull(customerDao);
        this.transactionDao = Objects.requireNonNull(transactionDao);
    }

    public PeriodSummary buildPeriodSummary(LocalDate from, LocalDate to) throws SQLException {
        Objects.requireNonNull(from, "from");
        Objects.requireNonNull(to, "to");
        if (to.isBefore(from)) throw new IllegalArgumentException("to must be on or after from");

        String f = from.toString();
        String t = to.toString();
        List<PeriodCustomerSummary> rows = new ArrayList<>();
        long totalDebits = 0;
        long totalCredits = 0;

        for (Customer c : customerDao.listAll()) {
            long debits = transactionDao.sumByTypeBetween(c.getCustomerId(), "DEBIT", f, t);
            long credits = transactionDao.sumByTypeBetween(c.getCustomerId(), "CREDIT", f, t);
            if (debits == 0 && credits == 0) continue;

            totalDebits += debits;
            totalCredits += credits;
            rows.add(new PeriodCustomerSummary(c.getCustomerId(), c.getName(), c.getPhone(), debits, credits));
        }

        return new PeriodSummary(rows, totalDebits, totalCredits);
    }

    public record PeriodSummary(List<PeriodCustomerSummary> rows, long totalDebitsPaise, long totalCreditsPaise) {
        public long netPaise() {
            return totalCreditsPaise - totalDebitsPaise;
        }
    }

    public record PeriodCustomerSummary(long customerId, String name, String phone, long debitsPaise, long creditsPaise) {
        public long netPaise() {
            return creditsPaise - debitsPaise;
        }
    }
}
