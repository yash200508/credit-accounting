package com.gasstation.app.service;

import com.gasstation.app.model.Transaction;

import java.time.LocalDate;
import java.time.temporal.ChronoUnit;
import java.util.*;

public class InterestCalculator {

    public static final double ANNUAL_RATE = 0.18;

    public static class StatementSummary {
        public long openingPrincipalPaise;
        public long debitsInRangePaise;
        public long creditsInRangePaise;
        public long closingPrincipalPaise;

        public long interestPaise; // interest for [from, to)
        public long totalDuePaise; // closingPrincipal + interest

        public LocalDate fromDate;
        public LocalDate toDate;
    }

    // Computes statement-style interest between [fromDate, toDate)
    // - FIFO payment allocation
    // - simple interest on outstanding principal
    public StatementSummary computeStatement(List<Transaction> txns, LocalDate fromDate, LocalDate toDate) {
        return computeStatementWithRate(txns, fromDate, toDate, ANNUAL_RATE);
    }

    /**
     * Same statement calculator, but uses a caller-provided annual interest rate.
     * This lets the business configure interest without changing code.
     */
    public StatementSummary computeStatementWithRate(List<Transaction> txns, LocalDate fromDate, LocalDate toDate, double annualRate) {
        if (fromDate == null || toDate == null) throw new IllegalArgumentException("Dates required");
        if (!toDate.isAfter(fromDate)) throw new IllegalArgumentException("To Date must be after From Date");

        // Sort by txn_date, then by id if available (not required)
        List<Transaction> list = new ArrayList<>(txns);
        list.sort(Comparator.comparing(t -> LocalDate.parse(t.getTxnDate())));

        // Build event list up to toDate (we need history to get opening principal)
        // We'll simulate outstanding debits with FIFO buckets.
        Deque<Bucket> buckets = new ArrayDeque<>();

        long debitsInRange = 0;
        long creditsInRange = 0;

        // We’ll compute interest by walking through time from fromDate -> toDate,
        // while applying any events (txns) on dates within that window.
        // But first we must apply all transactions BEFORE fromDate to get opening principal state.
        for (Transaction t : list) {
            LocalDate d = LocalDate.parse(t.getTxnDate());
            if (!d.isBefore(fromDate)) break;
            applyTxnToBuckets(buckets, t);
        }

        long openingPrincipal = sumBuckets(buckets);

        // Now compute interest from fromDate to toDate by segments.
        long interestAccruedPaise = 0;

        LocalDate cursor = fromDate;

        int idx = firstIndexOnOrAfter(list, fromDate);

        while (cursor.isBefore(toDate)) {
            LocalDate nextEventDate = toDate;

            // find next transaction date within [cursor, toDate)
            int j = idx;
            while (j < list.size()) {
                LocalDate td = LocalDate.parse(list.get(j).getTxnDate());
                if (td.isBefore(cursor)) { j++; continue; }
                if (!td.isBefore(toDate)) break;
                nextEventDate = td;
                break;
            }

            // Interest for [cursor, nextEventDate)
            long principalNow = sumBuckets(buckets);
            long days = ChronoUnit.DAYS.between(cursor, nextEventDate);
            if (days > 0 && principalNow > 0) {
                interestAccruedPaise += simpleInterestPaise(principalNow, days, annualRate);
            }

            cursor = nextEventDate;
            if (!cursor.isBefore(toDate)) break;

            // Apply all txns on this cursor date (could be multiple)
            while (idx < list.size()) {
                Transaction t = list.get(idx);
                LocalDate td = LocalDate.parse(t.getTxnDate());
                if (!td.equals(cursor)) break;

                // track range totals
                if (!td.isBefore(fromDate) && td.isBefore(toDate)) {
                    if ("DEBIT".equalsIgnoreCase(t.getTxnType())) debitsInRange += t.getAmountPaise();
                    else if ("CREDIT".equalsIgnoreCase(t.getTxnType())) creditsInRange += t.getAmountPaise();
                }

                applyTxnToBuckets(buckets, t);
                idx++;
            }
        }

        long closingPrincipal = sumBuckets(buckets);

        StatementSummary s = new StatementSummary();
        s.fromDate = fromDate;
        s.toDate = toDate;
        s.openingPrincipalPaise = openingPrincipal;
        s.debitsInRangePaise = debitsInRange;
        s.creditsInRangePaise = creditsInRange;
        s.closingPrincipalPaise = closingPrincipal;
        s.interestPaise = interestAccruedPaise;
        s.totalDuePaise = closingPrincipal + interestAccruedPaise;
        return s;
    }

    // ---------- Helpers ----------

    private static class Bucket {
        long remainingPaise;
        Bucket(long remainingPaise) { this.remainingPaise = remainingPaise; }
    }

    private void applyTxnToBuckets(Deque<Bucket> buckets, Transaction t) {
        String type = t.getTxnType() == null ? "" : t.getTxnType().trim().toUpperCase();
        long amt = t.getAmountPaise();

        if ("DEBIT".equals(type)) {
            buckets.addLast(new Bucket(amt));
            return;
        }

        if ("CREDIT".equals(type)) {
            long pay = amt;
            // FIFO: reduce oldest debit buckets
            while (pay > 0 && !buckets.isEmpty()) {
                Bucket b = buckets.peekFirst();
                long used = Math.min(pay, b.remainingPaise);
                b.remainingPaise -= used;
                pay -= used;
                if (b.remainingPaise == 0) buckets.removeFirst();
            }
        }
    }

    private long sumBuckets(Deque<Bucket> buckets) {
        long sum = 0;
        for (Bucket b : buckets) sum += b.remainingPaise;
        return sum;
    }

    private static int firstIndexOnOrAfter(List<Transaction> list, LocalDate date) {
        for (int i = 0; i < list.size(); i++) {
            LocalDate d = LocalDate.parse(list.get(i).getTxnDate());
            if (!d.isBefore(date)) return i;
        }
        return list.size();
    }

    private long simpleInterestPaise(long principalPaise, long days, double annualRate) {
        // interest = P * r * days/365
        // Do it in double then round to nearest paise
        double interest = principalPaise * annualRate * (days / 365.0);
        return Math.round(interest);
    }
}
