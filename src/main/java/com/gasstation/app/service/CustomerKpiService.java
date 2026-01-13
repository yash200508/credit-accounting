package com.gasstation.app.service;

import com.gasstation.app.dao.SettingsDao;
import com.gasstation.app.dao.TransactionDao;
import com.gasstation.app.model.Customer;
import com.gasstation.app.model.CustomerKpi;
import com.gasstation.app.model.Transaction;

import java.sql.SQLException;
import java.time.LocalDate;
import java.time.temporal.ChronoUnit;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.Deque;
import java.util.List;

/**
 * Builds business-facing metrics used by the Owner Dashboard:
 * - Who owes most (Total Due)
 * - Who is overdue (Days overdue, overdue amount)
 * - Who is paying regularly vs risky (risk tag)
 */
public class CustomerKpiService {

    public static final String KEY_RATE = "interest_annual_rate";
    public static final String KEY_GRACE_DAYS = "interest_grace_days";

    private final TransactionDao txnDao = new TransactionDao();
    private final SettingsDao settingsDao = new SettingsDao();
    private final InterestCalculator interestCalculator = new InterestCalculator();

    public CustomerKpi buildForCustomer(Customer c) throws SQLException {
        List<Transaction> txns = txnDao.listByCustomer(c.getCustomerId());
        txns.sort(Comparator.comparing(t -> LocalDate.parse(t.getTxnDate())));

        double annualRate = settingsDao.getDouble(KEY_RATE, InterestCalculator.ANNUAL_RATE);
        // Customer-specific collections policy
        int dueDays = c.getDueDays();
        int graceDays = c.getGraceDays();

        LocalDate today = LocalDate.now();
        LocalDate toDate = today.plusDays(1); // [from, to)

        // Principal + overdue details (FIFO)
        OutstandingState state = computeOutstandingState(txns, dueDays, graceDays, today);

        // Interest accrued since first ever txn date (simple + consistent)
        long interest = 0;
        long totalDue = state.principalPaise;

        if (!txns.isEmpty() && state.principalPaise > 0) {
            LocalDate from = LocalDate.parse(txns.get(0).getTxnDate());
            InterestCalculator.StatementSummary s = interestCalculator.computeStatementWithRate(txns, from, toDate, annualRate);
            interest = s.interestPaise;
            totalDue = s.totalDuePaise;
        }

        int daysOverdue = state.maxDaysPastDue;
        long overdueAmount = state.overduePaise;

        // Payments behavior
        LocalDate lastPayment = null;
        int payments30d = 0;
        LocalDate cutoff = today.minusDays(30);
        for (Transaction t : txns) {
            if (!"CREDIT".equalsIgnoreCase(t.getTxnType())) continue;
            LocalDate d = LocalDate.parse(t.getTxnDate());
            if (lastPayment == null || d.isAfter(lastPayment)) lastPayment = d;
            if (!d.isBefore(cutoff)) payments30d++;
        }

        // Risk scoring (simple & explainable)
        int score = 0;
        score += (daysOverdue >= 60 ? 60 : daysOverdue >= 30 ? 50 : daysOverdue >= 15 ? 25 : daysOverdue > 0 ? 10 : 0);

        long overdueCurrency = overdueAmount / 100; // rough thresholds in currency units
        score += (overdueCurrency >= 500 ? 30 : overdueCurrency >= 200 ? 15 : overdueCurrency > 0 ? 5 : 0);

        int daysSincePay = 999;
        if (lastPayment != null) daysSincePay = (int) ChronoUnit.DAYS.between(lastPayment, today);
        score += (daysSincePay >= 30 ? 20 : daysSincePay >= 15 ? 10 : 0);

        // Small bonus for regular payers
        if (payments30d >= 2) score -= 10;
        if (score < 0) score = 0;

        String tag = (score >= 70) ? "RED" : (score >= 25) ? "YELLOW" : "GREEN";

        CustomerKpi k = new CustomerKpi();
        k.setCustomer(c);
        k.setPrincipalBalancePaise(state.principalPaise);
        k.setInterestAccruedPaise(interest);
        k.setTotalDuePaise(totalDue);
        k.setOverdueAmountPaise(overdueAmount);
        k.setMaxDaysOverdue(daysOverdue);
        k.setLastPaymentDate(lastPayment);
        k.setPaymentsLast30Days(payments30d);
        k.setRiskScore(score);
        k.setRiskTag(tag);
        return k;
    }

    public List<CustomerKpi> buildForCustomers(List<Customer> customers) throws SQLException {
        List<CustomerKpi> out = new ArrayList<>();
        for (Customer c : customers) out.add(buildForCustomer(c));
        return out;
    }

    // ----- FIFO state with dates (for overdue) -----

    private static class DatedBucket {
        LocalDate date;
        long remaining;
        DatedBucket(LocalDate date, long remaining) {
            this.date = date;
            this.remaining = remaining;
        }
    }

    private static class OutstandingState {
        long principalPaise;
        long overduePaise;
        int maxDaysPastDue;
    }

    private OutstandingState computeOutstandingState(List<Transaction> txns, int dueDays, int graceDays, LocalDate today) {
        Deque<DatedBucket> buckets = new ArrayDeque<>();
        for (Transaction t : txns) {
            LocalDate d = LocalDate.parse(t.getTxnDate());
            String type = t.getTxnType() == null ? "" : t.getTxnType().trim().toUpperCase();
            long amt = t.getAmountPaise();

            if ("DEBIT".equals(type)) {
                buckets.addLast(new DatedBucket(d, amt));
            } else if ("CREDIT".equals(type)) {
                long pay = amt;
                while (pay > 0 && !buckets.isEmpty()) {
                    DatedBucket b = buckets.peekFirst();
                    long used = Math.min(pay, b.remaining);
                    b.remaining -= used;
                    pay -= used;
                    if (b.remaining == 0) buckets.removeFirst();
                }
            }
        }

        OutstandingState s = new OutstandingState();
        long principal = 0;
        long overdue = 0;
        int maxPastDue = 0;

        for (DatedBucket b : buckets) {
            principal += b.remaining;

            // Per-bucket due date
            LocalDate dueDate = b.date.plusDays(Math.max(0, dueDays));
            int daysPastDue = (int) ChronoUnit.DAYS.between(dueDate, today);
            if (daysPastDue < 0) daysPastDue = 0;
            if (daysPastDue > maxPastDue) maxPastDue = daysPastDue;

            // Grace days means: only treat as overdue once beyond grace
            if (daysPastDue > Math.max(0, graceDays)) {
                overdue += b.remaining;
            }
        }

        s.principalPaise = principal;
        s.overduePaise = overdue;
        s.maxDaysPastDue = maxPastDue;
        return s;
    }
}
