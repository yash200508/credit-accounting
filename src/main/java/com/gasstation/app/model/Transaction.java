package com.gasstation.app.model;

/**
 * Transaction model.
 *
 * Money is stored in paise (integer) to avoid floating point rounding issues.
 *
 * Status rule:
 * - POSTED: affects balances/reports
 * - VOID  : MUST be excluded everywhere (DAOs already filter it out)
 */
public class Transaction {

    private long txnId;
    private long customerId;

    /** YYYY-MM-DD */
    private String txnDate;

    /** "DEBIT" (fuel given) or "CREDIT" (payment received) */
    private String txnType;

    /** Amount in paise (always positive) */
    private long amountPaise;

    private String reference;
    private String notes;

    // Accounting safety
    private String status = "POSTED"; // POSTED / VOID
    private String voidReason;
    private String voidedAt; // ISO datetime

    // UI-only (not stored in DB)
    private long runningBalancePaise;

    public Transaction() {}

    public long getTxnId() {
        return txnId;
    }

    public void setTxnId(long txnId) {
        this.txnId = txnId;
    }

    public long getCustomerId() {
        return customerId;
    }

    public void setCustomerId(long customerId) {
        this.customerId = customerId;
    }

    public String getTxnDate() {
        return txnDate;
    }

    public void setTxnDate(String txnDate) {
        this.txnDate = txnDate;
    }

    public String getTxnType() {
        return txnType;
    }

    public void setTxnType(String txnType) {
        this.txnType = txnType;
    }

    public long getAmountPaise() {
        return amountPaise;
    }

    public void setAmountPaise(long amountPaise) {
        this.amountPaise = amountPaise;
    }

    public String getReference() {
        return reference;
    }

    public void setReference(String reference) {
        this.reference = reference;
    }

    public String getNotes() {
        return notes;
    }

    public void setNotes(String notes) {
        this.notes = notes;
    }

    public String getStatus() {
        return status;
    }

    public void setStatus(String status) {
        this.status = status;
    }

    public String getVoidReason() {
        return voidReason;
    }

    public void setVoidReason(String voidReason) {
        this.voidReason = voidReason;
    }

    public String getVoidedAt() {
        return voidedAt;
    }

    public void setVoidedAt(String voidedAt) {
        this.voidedAt = voidedAt;
    }

    public long getRunningBalancePaise() {
        return runningBalancePaise;
    }

    public void setRunningBalancePaise(long runningBalancePaise) {
        this.runningBalancePaise = runningBalancePaise;
    }
}
