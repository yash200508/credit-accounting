package com.gasstation.app.service;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

class TransactionImportValidatorTest {

    @Test
    void parsesValidTransactionImportAmounts() {
        assertEquals(1_234L, TransactionImportValidator.parseRupeesToPaise("12.34"));
        assertEquals(123_450L, TransactionImportValidator.parseRupeesToPaise("Rs. 1,234.50"));
        assertEquals(123_450L, TransactionImportValidator.parseRupeesToPaise("₹1,234.50"));
    }

    @Test
    void rejectsOverPreciseAndInvalidAmountsAsZeroForImportSkipping() {
        assertEquals(0L, TransactionImportValidator.parseRupeesToPaise("12.345"));
        assertEquals(0L, TransactionImportValidator.parseRupeesToPaise("abc"));
        assertEquals(0L, TransactionImportValidator.parseRupeesToPaise(""));
    }

    @Test
    void normalizesSupportedTransactionTypes() {
        assertEquals("DEBIT", TransactionImportValidator.normalizeType("DEBIT"));
        assertEquals("CREDIT", TransactionImportValidator.normalizeType("CREDIT"));
        assertEquals("DEBIT", TransactionImportValidator.normalizeType("Credit Taken"));
        assertEquals("DEBIT", TransactionImportValidator.normalizeType("fuel sale"));
        assertEquals("CREDIT", TransactionImportValidator.normalizeType("payment received"));
        assertEquals("CREDIT", TransactionImportValidator.normalizeType("paid"));
    }

    @Test
    void rejectsInvalidTransactionTypesAndMissingRequiredFields() {
        assertNull(TransactionImportValidator.normalizeType("adjustment"));
        assertNull(TransactionImportValidator.normalizeType(null));

        assertTrue(TransactionImportValidator.hasRequiredFields("9999999999", "2026-01-01", "DEBIT", "12.00", ""));
        assertTrue(TransactionImportValidator.hasRequiredFields("9999999999", "2026-01-01", "DEBIT", "", "1200"));
        assertFalse(TransactionImportValidator.hasRequiredFields("", "2026-01-01", "DEBIT", "12.00", ""));
        assertFalse(TransactionImportValidator.hasRequiredFields("9999999999", "", "DEBIT", "12.00", ""));
        assertFalse(TransactionImportValidator.hasRequiredFields("9999999999", "2026-01-01", "", "12.00", ""));
        assertFalse(TransactionImportValidator.hasRequiredFields("9999999999", "2026-01-01", "DEBIT", "", ""));
    }
}
