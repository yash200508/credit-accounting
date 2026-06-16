package com.gasstation.app.service;

import com.gasstation.app.service.CustomerImportValidator.CustomerImportRow;
import org.junit.jupiter.api.Test;

import java.util.Set;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class CustomerImportValidatorTest {

    @Test
    void validatesAndNormalizesValidCustomerRows() {
        CustomerImportRow row = CustomerImportValidator.validate(
                "  Ravi  ",
                "+91 98765 43210",
                "inactive",
                "1,234.50",
                "",
                "15",
                "3",
                Set.of()
        );

        assertTrue(row.valid());
        assertEquals("Ravi", row.name());
        assertEquals("9876543210", row.phone());
        assertEquals(0, row.isActive());
        assertEquals(123_450L, row.creditLimitPaise());
        assertEquals(15, row.dueDays());
        assertEquals(3, row.graceDays());
    }

    @Test
    void rejectsMissingRequiredNameOrPhoneAndDuplicatePhone() {
        assertInvalid("Missing required fields (Name/Phone)", CustomerImportValidator.validate("", "9876543210", "", "", "", "", "", Set.of()));
        assertInvalid("Missing required fields (Name/Phone)", CustomerImportValidator.validate("Ravi", "12345", "", "", "", "", "", Set.of()));
        assertInvalid("Duplicate phone: 9876543210", CustomerImportValidator.validate("Ravi", "9876543210", "", "", "", "", "", Set.of("9876543210")));
    }

    @Test
    void parsesCreditLimitPaiseColumnBeforeRupeeColumn() {
        CustomerImportRow row = CustomerImportValidator.validate(
                "Ravi", "9876543210", "", "999.99", "12345", "", "", Set.of());

        assertTrue(row.valid());
        assertEquals(12_345L, row.creditLimitPaise());
    }

    @Test
    void rejectsOverPreciseCreditLimitWithoutSilentTruncation() {
        CustomerImportRow row = CustomerImportValidator.validate(
                "Ravi", "9876543210", "", "100.999", "", "", "", Set.of());

        assertTrue(row.valid());
        assertEquals(0L, row.creditLimitPaise(), "over-precise money must be rejected instead of truncated");
    }

    @Test
    void defaultsAndBoundsOptionalPolicyFields() {
        CustomerImportRow row = CustomerImportValidator.validate(
                "Ravi", "9876543210", "yes", "", "", "bad", "-5", Set.of());

        assertTrue(row.valid());
        assertEquals(1, row.isActive());
        assertEquals(30, row.dueDays());
        assertEquals(0, row.graceDays());
        assertEquals(0L, row.creditLimitPaise());
    }

    private static void assertInvalid(String expectedReason, CustomerImportRow row) {
        assertFalse(row.valid());
        assertEquals(expectedReason, row.failureReason());
    }
}
