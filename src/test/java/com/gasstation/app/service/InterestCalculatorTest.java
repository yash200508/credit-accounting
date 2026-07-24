package com.gasstation.app.service;

import com.gasstation.app.model.Transaction;
import org.junit.jupiter.api.Test;

import java.time.LocalDate;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class InterestCalculatorTest {

    private final InterestCalculator calculator = new InterestCalculator();

    @Test
    void computesSimpleInterestOverDateRange() {
        InterestCalculator.StatementSummary summary = calculator.computeStatementWithRate(
                List.of(txn("2026-01-01", "DEBIT", 100_000L)),
                LocalDate.parse("2026-01-01"),
                LocalDate.parse("2026-01-11"),
                0.365);

        assertEquals(0L, summary.openingPrincipalPaise);
        assertEquals(100_000L, summary.debitsInRangePaise);
        assertEquals(0L, summary.creditsInRangePaise);
        assertEquals(100_000L, summary.closingPrincipalPaise);
        assertEquals(1_000L, summary.interestPaise);
        assertEquals(101_000L, summary.totalDuePaise);
    }

    @Test
    void appliesCreditsFifoAndAccruesInterestByPrincipalSegment() {
        InterestCalculator.StatementSummary summary = calculator.computeStatementWithRate(
                List.of(
                        txn("2026-01-01", "DEBIT", 100_000L),
                        txn("2026-01-06", "CREDIT", 40_000L)
                ),
                LocalDate.parse("2026-01-01"),
                LocalDate.parse("2026-01-11"),
                0.365);

        assertEquals(100_000L, summary.debitsInRangePaise);
        assertEquals(40_000L, summary.creditsInRangePaise);
        assertEquals(60_000L, summary.closingPrincipalPaise);
        assertEquals(800L, summary.interestPaise);
        assertEquals(60_800L, summary.totalDuePaise);
    }

    @Test
    void includesOpeningPrincipalFromTransactionsBeforeRange() {
        InterestCalculator.StatementSummary summary = calculator.computeStatementWithRate(
                List.of(
                        txn("2025-12-20", "DEBIT", 50_000L),
                        txn("2026-01-03", "DEBIT", 25_000L),
                        txn("2026-01-05", "CREDIT", 10_000L)
                ),
                LocalDate.parse("2026-01-01"),
                LocalDate.parse("2026-01-06"),
                0.365);

        assertEquals(50_000L, summary.openingPrincipalPaise);
        assertEquals(25_000L, summary.debitsInRangePaise);
        assertEquals(10_000L, summary.creditsInRangePaise);
        assertEquals(65_000L, summary.closingPrincipalPaise);
        // 50,000 * 2 days + 75,000 * 2 days + 65,000 * 1 day at 0.1% per day.
        assertEquals(315L, summary.interestPaise);
    }

    @Test
    void rejectsMissingOrInvalidDateRange() {
        assertThrows(IllegalArgumentException.class,
                () -> calculator.computeStatement(List.of(), null, LocalDate.parse("2026-01-01")));
        assertThrows(IllegalArgumentException.class,
                () -> calculator.computeStatement(List.of(), LocalDate.parse("2026-01-01"), LocalDate.parse("2026-01-01")));
    }

    private static Transaction txn(String date, String type, long amountPaise) {
        Transaction txn = new Transaction();
        txn.setTxnDate(date);
        txn.setTxnType(type);
        txn.setAmountPaise(amountPaise);
        return txn;
    }
}
