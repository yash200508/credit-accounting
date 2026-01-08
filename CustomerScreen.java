package com.gasstation.app;

import com.gasstation.app.dao.CustomerDao;
import com.gasstation.app.model.Customer;
import com.gasstation.app.db.Db;
import javafx.animation.PauseTransition;
import javafx.beans.property.SimpleStringProperty;
import javafx.collections.FXCollections;
import javafx.collections.ObservableList;
import javafx.concurrent.Task;
import javafx.geometry.Insets;
import javafx.scene.control.*;
import javafx.scene.control.cell.PropertyValueFactory;
import javafx.scene.layout.*;
import javafx.util.Duration;
import java.util.List;


import java.awt.Desktop;
import java.net.URI;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.LocalDate;
import java.util.ArrayList;

import java.util.Optional;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Customer screen with:
 * - Fast debounced search
 * - DB pagination (works even for huge customer counts)
 * - Edit Customer Name (new)
 * - Existing phone history / edit details / credit settings / active toggle
 */
public class CustomerScreen extends BorderPane {

    private static final int PAGE_SIZE = 100;

    private final AppNavigator nav;
    private final CustomerDao customerDao = new CustomerDao();

    // Run DB work off the JavaFX UI thread to prevent UI freezes.
    private final ExecutorService dbPool = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "db-customer-screen");
        t.setDaemon(true);
        return t;
    });

    // Small debounce so rapid typing doesn't trigger multiple searches.
    private final PauseTransition searchDebounce = new PauseTransition(Duration.millis(140));
    private long searchSeq = 0L; // used to ignore stale results

    // Pagination state
    private final Pagination pagination = new Pagination();
    private int totalCount = 0;
    private String activeQuery = "";     // "" => browsing all customers
    private boolean includeInactive = true;

    // UI
    private final TextField searchField = new TextField();
    private final Button searchBtn = new Button("Search");
    private final Button clearBtn = new Button("Clear");

    private final Button editNameBtn = new Button("Edit Name");
    private final Button editPhoneBtn = new Button("Edit Phone");
    private final Button viewPhoneHistoryBtn = new Button("Phone History");
    private final Button editDetailsBtn = new Button("Edit Details");
    private final Button creditSettingsBtn = new Button("Credit Settings");
    private final Button toggleActiveBtn = new Button("Deactivate");
    private final Button callBtn = new Button("Call");
    private final Button whatsappBtn = new Button("WhatsApp");

    private final ObservableList<Customer> tableData = FXCollections.observableArrayList();
    private final TableView<Customer> table = new TableView<>(tableData);

    // Add customer form
    private final TextField nameField = new TextField();
    private final TextField phoneField = new TextField();
    private final TextField addressField = new TextField();
    private final TextArea notesField = new TextArea();
    private final Button addCustomerBtn = new Button("Add Customer");

    private final Label statusLabel = new Label("");

    public CustomerScreen(AppNavigator nav) {
        this.nav = nav;

        setPadding(new Insets(12));

        configureTable();
        wireActions();
        setupTablePerformance();

        setTop(buildTopBar());
        setCenter(buildTableWithPagination());
        setRight(buildAddCustomerPanel());
        setBottom(buildStatusBar());

        // Initial load (paged) so app stays fast even with huge customer counts.
        loadCountsAndFirstPageAsync();
    }

    /* =========================
       UI BUILDERS
       ========================= */

    private Pane buildTopBar() {
        searchField.setPromptText("Search by name or phone...");
        searchField.setPrefWidth(360);

        setButtonsEnabled(false);

        HBox bar = new HBox(
                10,
                new Label("Customer Search:"),
                searchField,
                searchBtn,
                clearBtn,
                new Separator(),
                editNameBtn,
                editPhoneBtn,
                viewPhoneHistoryBtn,
                editDetailsBtn,
                creditSettingsBtn,
                toggleActiveBtn,
                new Separator(),
                callBtn,
                whatsappBtn
        );
        bar.setPadding(new Insets(0, 0, 12, 0));
        return bar;
    }

    private Pane buildTableWithPagination() {
        pagination.setMaxWidth(Double.MAX_VALUE);

        // Pagination requires a Node per page; we render results inside table, so return empty Pane.
        pagination.setPageFactory(pageIndex -> {
            loadPageAsync(pageIndex);
            return new Pane();
        });

        VBox box = new VBox(8, table, pagination);
        VBox.setVgrow(table, Priority.ALWAYS);

        box.setPadding(new Insets(0, 12, 0, 0));
        return box;
    }

    private Pane buildAddCustomerPanel() {
        Label title = new Label("Add New Customer");

        nameField.setPromptText("Name");
        phoneField.setPromptText("Phone (10 digits)");
        addressField.setPromptText("Address (optional)");

        notesField.setPromptText("Notes (optional)");
        notesField.setPrefRowCount(4);

        GridPane form = new GridPane();
        form.setHgap(8);
        form.setVgap(8);

        form.add(new Label("Name*"), 0, 0);
        form.add(nameField, 1, 0);

        form.add(new Label("Phone*"), 0, 1);
        form.add(phoneField, 1, 1);

        form.add(new Label("Address"), 0, 2);
        form.add(addressField, 1, 2);

        form.add(new Label("Notes"), 0, 3);
        form.add(notesField, 1, 3);

        ColumnConstraints c0 = new ColumnConstraints();
        c0.setMinWidth(70);
        ColumnConstraints c1 = new ColumnConstraints();
        c1.setHgrow(Priority.ALWAYS);
        form.getColumnConstraints().addAll(c0, c1);

        VBox panel = new VBox(10, title, form, addCustomerBtn);
        panel.setPadding(new Insets(0, 0, 0, 12));
        panel.setPrefWidth(320);
        panel.setStyle("-fx-border-color: #444; -fx-border-radius: 6; -fx-padding: 12;");

        return panel;
    }

    private Pane buildStatusBar() {
        HBox bar = new HBox(statusLabel);
        bar.setPadding(new Insets(12, 0, 0, 0));
        return bar;
    }

    /* =========================
       TABLE SETUP
       ========================= */

    private void configureTable() {
        TableColumn<Customer, Long> idCol = new TableColumn<>("ID");
        idCol.setCellValueFactory(new PropertyValueFactory<>("customerId"));
        idCol.setPrefWidth(70);

        TableColumn<Customer, String> nameCol = new TableColumn<>("Name");
        nameCol.setCellValueFactory(new PropertyValueFactory<>("name"));
        nameCol.setPrefWidth(220);

        TableColumn<Customer, String> phoneCol = new TableColumn<>("Phone");
        phoneCol.setCellValueFactory(new PropertyValueFactory<>("phone"));
        phoneCol.setPrefWidth(140);

        TableColumn<Customer, String> addressCol = new TableColumn<>("Address");
        addressCol.setCellValueFactory(new PropertyValueFactory<>("address"));
        addressCol.setPrefWidth(250);
        addressCol.setCellFactory(col -> new TruncCell(28));

        TableColumn<Customer, String> notesCol = new TableColumn<>("Notes");
        notesCol.setCellValueFactory(new PropertyValueFactory<>("notes"));
        notesCol.setPrefWidth(250);
        notesCol.setCellFactory(col -> new TruncCell(28));

        TableColumn<Customer, String> activeCol = new TableColumn<>("Status");
        activeCol.setCellValueFactory(c -> {
            try {
                int a = c.getValue().getIsActive();
                return new SimpleStringProperty(a == 1 ? "Active" : "Inactive");
            } catch (Exception ex) {
                return new SimpleStringProperty("");
            }
        });
        activeCol.setPrefWidth(90);

        table.getColumns().setAll(List.of(idCol, nameCol, phoneCol, addressCol, notesCol, activeCol));
        table.setColumnResizePolicy(TableView.CONSTRAINED_RESIZE_POLICY);
        table.setPlaceholder(new Label("No customers to show."));

        // Enable/disable buttons based on selection
        table.getSelectionModel().selectedItemProperty().addListener((obs, oldV, sel) -> {
            boolean has = sel != null;
            setButtonsEnabled(has);
            if (sel != null) updateToggleActiveText(sel);
        });

        // Double click -> open ledger
        table.setRowFactory(tv -> {
            TableRow<Customer> row = new TableRow<>();
            row.setOnMouseClicked(event -> {
                if (event.getClickCount() == 2 && (!row.isEmpty())) {
                    nav.showLedger(row.getItem());
                }
            });
            return row;
        });
    }

    private void setupTablePerformance() {
        // Reduces layout/CPU spikes when selecting rows with long strings.
        table.setFixedCellSize(28);
    }

    private void setButtonsEnabled(boolean enabled) {
        editNameBtn.setDisable(!enabled);
        editPhoneBtn.setDisable(!enabled);
        viewPhoneHistoryBtn.setDisable(!enabled);
        editDetailsBtn.setDisable(!enabled);
        creditSettingsBtn.setDisable(!enabled);
        toggleActiveBtn.setDisable(!enabled);
        callBtn.setDisable(!enabled);
        whatsappBtn.setDisable(!enabled);
    }

    /* =========================
       SEARCH + PAGINATION
       ========================= */

    private void wireActions() {
        searchBtn.setOnAction(e -> scheduleSearch());
        searchField.setOnAction(e -> scheduleSearch());

        // Debounced "search while typing" (remove this if you want manual-only search)
        searchField.textProperty().addListener((obs, oldV, v) -> {
            if (v == null) return;
            if (v.trim().isEmpty()) return;
            scheduleSearch();
        });

        clearBtn.setOnAction(e -> {
            // Cancel any in-flight debounced search.
            searchSeq++;
            searchDebounce.stop();

            searchField.clear();
            activeQuery = "";
            setStatus("Showing all customers...");
            loadCountsAndFirstPageAsync();
        });

        addCustomerBtn.setOnAction(e -> addCustomer());

        editNameBtn.setOnAction(e -> editSelectedCustomerName());
        editPhoneBtn.setOnAction(e -> editSelectedCustomerPhone());
        viewPhoneHistoryBtn.setOnAction(e -> showPhoneHistory());
        editDetailsBtn.setOnAction(e -> editCustomerDetails());
        creditSettingsBtn.setOnAction(e -> editCreditSettings());
        toggleActiveBtn.setOnAction(e -> toggleActive());

        callBtn.setOnAction(e -> callSelected());
        whatsappBtn.setOnAction(e -> whatsappSelected());
    }

    private void scheduleSearch() {
        final String q = safe(searchField.getText());
        final long seq = ++searchSeq;

        searchDebounce.setOnFinished(e -> runSearch(seq, q));
        searchDebounce.playFromStart();
    }

    private void runSearch(long seq, String q) {
        activeQuery = safe(q);

        // If empty, treat it as browsing-all mode.
        if (activeQuery.isEmpty()) {
            loadCountsAndFirstPageAsync();
            return;
        }

        searchBtn.setDisable(true);
        clearBtn.setDisable(true);
        setStatus("Searching...");

        Task<Integer> countTask = new Task<>() {
            @Override
            protected Integer call() throws Exception {
                return customerDao.countByNameOrPhone(activeQuery, includeInactive);
            }
        };

        countTask.setOnSucceeded(e -> {
            if (seq != searchSeq) {
                searchBtn.setDisable(false);
                clearBtn.setDisable(false);
                return;
            }
            totalCount = countTask.getValue();
            updatePagination(totalCount);
            pagination.setCurrentPageIndex(0);
            loadPageAsync(0);

            searchBtn.setDisable(false);
            clearBtn.setDisable(false);
        });

        countTask.setOnFailed(e -> {
            if (seq != searchSeq) {
                searchBtn.setDisable(false);
                clearBtn.setDisable(false);
                return;
            }
            searchBtn.setDisable(false);
            clearBtn.setDisable(false);
            showError("Search failed", countTask.getException());
        });

        dbPool.submit(countTask);
    }

    private void loadCountsAndFirstPageAsync() {
        final long seq = ++searchSeq;

        searchBtn.setDisable(true);
        clearBtn.setDisable(true);
        setStatus("Loading...");

        Task<Integer> countTask = new Task<>() {
            @Override
            protected Integer call() throws Exception {
                return customerDao.countAllCustomers(includeInactive);
            }
        };

        countTask.setOnSucceeded(e -> {
            if (seq != searchSeq) {
                searchBtn.setDisable(false);
                clearBtn.setDisable(false);
                return;
            }
            totalCount = countTask.getValue();
            updatePagination(totalCount);
            pagination.setCurrentPageIndex(0);
            loadPageAsync(0);

            searchBtn.setDisable(false);
            clearBtn.setDisable(false);
        });

        countTask.setOnFailed(e -> {
            if (seq != searchSeq) {
                searchBtn.setDisable(false);
                clearBtn.setDisable(false);
                return;
            }
            searchBtn.setDisable(false);
            clearBtn.setDisable(false);
            showError("Load failed", countTask.getException());
        });

        dbPool.submit(countTask);
    }

    private void updatePagination(int total) {
        int pages = Math.max(1, (int) Math.ceil(total / (double) PAGE_SIZE));
        pagination.setPageCount(pages);
    }

    private void loadPageAsync(int pageIndex) {
        final long seq = searchSeq;
        final int offset = Math.max(0, pageIndex) * PAGE_SIZE;

        Task<List<Customer>> task = new Task<>() {
            @Override
            protected List<Customer> call() throws Exception {
                if (activeQuery == null || activeQuery.isBlank()) {
                    return customerDao.listPageAll(PAGE_SIZE, offset, includeInactive);
                }
                return customerDao.searchPageByNameOrPhone(activeQuery, PAGE_SIZE, offset, includeInactive);
            }
        };

        task.setOnSucceeded(e -> {
            if (seq != searchSeq) return;
            tableData.setAll(task.getValue());
            setStatus(buildResultStatus(pageIndex));
            table.getSelectionModel().clearSelection();
        });

        task.setOnFailed(e -> {
            if (seq != searchSeq) return;
            showError("Load page failed", task.getException());
        });

        dbPool.submit(task);
    }

    private String buildResultStatus(int pageIndex) {
        if (totalCount <= 0) return "No results.";
        int from = pageIndex * PAGE_SIZE + 1;
        int to = Math.min(totalCount, (pageIndex + 1) * PAGE_SIZE);
        String mode = (activeQuery == null || activeQuery.isBlank()) ? "All customers" : ("Search: \"" + activeQuery + "\"");
        return mode + "  •  Showing " + from + "-" + to + " of " + totalCount;
    }

    /* =========================
       ADD CUSTOMER
       ========================= */

    private void addCustomer() {
        String name = safe(nameField.getText());
        String phone = safe(phoneField.getText());

        if (name.isEmpty()) {
            setStatus("Name is required.");
            return;
        }
        if (digitsOnly(phone).length() < 10) {
            setStatus("Phone must have 10 digits.");
            return;
        }

        Customer c = new Customer(
                name,
                phone,
                safe(addressField.getText()),
                safe(notesField.getText())
        );

        try {
            long id = customerDao.insert(c);
            setStatus("Customer added. ID=" + id);

            nameField.clear();
            phoneField.clear();
            addressField.clear();
            notesField.clear();

            // Refresh current mode
            if (safe(searchField.getText()).isEmpty()) {
                loadCountsAndFirstPageAsync();
            } else {
                scheduleSearch();
            }

        } catch (SQLException ex) {
            String msg = ex.getMessage() == null ? "" : ex.getMessage().toLowerCase();

            if (msg.contains("unique") && msg.contains("phone")) {
                Alert a = new Alert(Alert.AlertType.WARNING);
                a.setTitle("Phone already exists");
                a.setHeaderText("Customer already exists with this phone number");
                a.setContentText("Please search using this phone number and update the existing customer instead of creating a new one.");
                a.showAndWait();
                setStatus("Phone already exists. Use search to find the customer.");
                return;
            }

            showError("Add customer failed", ex);
        }
    }

    /* =========================
       EDIT NAME (NEW)
       ========================= */

    private void editSelectedCustomerName() {
        Customer selected = table.getSelectionModel().getSelectedItem();
        if (selected == null) {
            setStatus("Select a customer first.");
            return;
        }

        TextInputDialog dialog = new TextInputDialog(safe(selected.getName()));
        dialog.setTitle("Edit Customer Name");
        dialog.setHeaderText("Customer ID: " + selected.getCustomerId());
        dialog.setContentText("New name:");

        Optional<String> res = dialog.showAndWait();
        if (res.isEmpty()) return;

        String newName = safe(res.get());
        if (newName.isEmpty()) {
            new Alert(Alert.AlertType.WARNING, "Name cannot be empty.").showAndWait();
            return;
        }
        if (newName.length() > 60) {
            new Alert(Alert.AlertType.WARNING, "Name too long (max 60 characters).").showAndWait();
            return;
        }
        if (newName.equals(safe(selected.getName()))) return;

        Task<Void> task = new Task<>() {
            @Override
            protected Void call() throws Exception {
                customerDao.updateCustomerName(selected.getCustomerId(), newName);
                return null;
            }
        };

        task.setOnSucceeded(e -> {
            selected.setName(newName);
            table.refresh();
            setStatus("Customer name updated.");
        });

        task.setOnFailed(e -> showError("Update name failed", task.getException()));

        dbPool.submit(task);
    }

    /* =========================
       EDIT PHONE
       ========================= */

    private void editSelectedCustomerPhone() {
        Customer selected = table.getSelectionModel().getSelectedItem();
        if (selected == null) {
            setStatus("Select a customer first.");
            return;
        }

        Dialog<ButtonType> dialog = new Dialog<>();
        dialog.setTitle("Update Phone Number");
        dialog.setHeaderText("Customer: " + safe(selected.getName()) + " (ID: " + selected.getCustomerId() + ")");

        ButtonType saveBtn = new ButtonType("Save", ButtonBar.ButtonData.OK_DONE);
        dialog.getDialogPane().getButtonTypes().addAll(saveBtn, ButtonType.CANCEL);

        TextField newPhoneField = new TextField();
        newPhoneField.setPromptText("New phone (10 digits)");
        newPhoneField.setPrefColumnCount(18);

        TextField noteField = new TextField();
        noteField.setPromptText("Note (optional) e.g., changed SIM");

        GridPane gp = new GridPane();
        gp.setHgap(10);
        gp.setVgap(10);
        gp.setPadding(new Insets(12));
        gp.add(new Label("New phone:"), 0, 0);
        gp.add(newPhoneField, 1, 0);
        gp.add(new Label("Note:"), 0, 1);
        gp.add(noteField, 1, 1);

        dialog.getDialogPane().setContent(gp);

        Button saveButton = (Button) dialog.getDialogPane().lookupButton(saveBtn);
        saveButton.setDisable(true);

        newPhoneField.textProperty().addListener((obs, oldV, v) ->
                saveButton.setDisable(digitsOnly(v).length() < 10)
        );

        dialog.showAndWait().ifPresent(btn -> {
            if (btn == saveBtn) {
                String newPhone = safe(newPhoneField.getText());
                String note = safe(noteField.getText());

                try {
                    customerDao.updateCustomerPhone(
                            selected.getCustomerId(),
                            newPhone,
                            "admin",
                            note
                    );

                    // update in-memory (last 10 digits)
                    String d = digitsOnly(newPhone);
                    if (d.length() > 10) d = d.substring(d.length() - 10);
                    selected.setPhone(d);

                    table.refresh();
                    setStatus("Phone updated for customer ID=" + selected.getCustomerId());

                } catch (RuntimeException ex) {
                    String msg = (ex.getMessage() == null ? "" : ex.getMessage().toLowerCase());
                    String cause = (ex.getCause() != null && ex.getCause().getMessage() != null)
                            ? ex.getCause().getMessage().toLowerCase()
                            : "";

                    if (msg.contains("unique") || cause.contains("unique")) {
                        new Alert(Alert.AlertType.ERROR,
                                "This phone number is already used by another customer.").showAndWait();
                    } else {
                        showError("Update phone failed", ex);
                    }
                }
            }
        });
    }

    /* =========================
       PHONE HISTORY
       ========================= */

    private void showPhoneHistory() {
        Customer selected = table.getSelectionModel().getSelectedItem();
        if (selected == null) {
            setStatus("Select a customer first.");
            return;
        }

        List<PhoneHistoryRow> rows;
        try {
            rows = loadPhoneHistory(selected.getCustomerId());
        } catch (SQLException ex) {
            showError("Failed to load phone history", ex);
            return;
        }

        TableView<PhoneHistoryRow> histTable = new TableView<>();
        histTable.setItems(FXCollections.observableArrayList(rows));
        histTable.setColumnResizePolicy(TableView.CONSTRAINED_RESIZE_POLICY);

        TableColumn<PhoneHistoryRow, String> oldCol = new TableColumn<>("Old");
        oldCol.setCellValueFactory(d -> new SimpleStringProperty(d.getValue().oldPhone));

        TableColumn<PhoneHistoryRow, String> newCol = new TableColumn<>("New");
        newCol.setCellValueFactory(d -> new SimpleStringProperty(d.getValue().newPhone));

        TableColumn<PhoneHistoryRow, String> atCol = new TableColumn<>("Changed At");
        atCol.setCellValueFactory(d -> new SimpleStringProperty(d.getValue().changedAt));

        TableColumn<PhoneHistoryRow, String> noteCol = new TableColumn<>("Note");
        noteCol.setCellValueFactory(d -> new SimpleStringProperty(d.getValue().note));

        histTable.getColumns().setAll(List.of(oldCol, newCol, atCol, noteCol));


        Dialog<ButtonType> dialog = new Dialog<>();
        dialog.setTitle("Phone History");
        dialog.setHeaderText("Customer: " + safe(selected.getName()) + " (ID: " + selected.getCustomerId() + ")");
        dialog.getDialogPane().getButtonTypes().addAll(ButtonType.CLOSE);

        VBox content = new VBox(10, histTable);
        content.setPadding(new Insets(12));
        VBox.setVgrow(histTable, Priority.ALWAYS);

        dialog.getDialogPane().setContent(content);
        dialog.getDialogPane().setPrefSize(720, 420);
        dialog.showAndWait();
    }

    private List<PhoneHistoryRow> loadPhoneHistory(long customerId) throws SQLException {
        String sql = """
            SELECT old_phone, new_phone, changed_at, note
            FROM customer_phone_history
            WHERE customer_id = ?
            ORDER BY datetime(changed_at) DESC;
        """;

        List<PhoneHistoryRow> out = new ArrayList<>();
        try (Connection conn = Db.getConnection();
             PreparedStatement ps = conn.prepareStatement(sql)) {

            ps.setLong(1, customerId);

            try (ResultSet rs = ps.executeQuery()) {
                while (rs.next()) {
                    PhoneHistoryRow r = new PhoneHistoryRow();
                    r.oldPhone = rs.getString("old_phone");
                    r.newPhone = rs.getString("new_phone");
                    r.changedAt = rs.getString("changed_at");
                    r.note = rs.getString("note");
                    out.add(r);
                }
            }
        }
        return out;
    }

    private static class PhoneHistoryRow {
        String oldPhone;
        String newPhone;
        String changedAt;
        String note;
    }

    /* =========================
       EDIT DETAILS (Address + Notes)
       ========================= */

    private void editCustomerDetails() {
        Customer c = table.getSelectionModel().getSelectedItem();
        if (c == null) return;

        Dialog<ButtonType> dialog = new Dialog<>();
        dialog.setTitle("Edit Customer Details");
        dialog.setHeaderText("Customer: " + safe(c.getName()) + " (ID: " + c.getCustomerId() + ")");

        ButtonType saveBtn = new ButtonType("Save", ButtonBar.ButtonData.OK_DONE);
        dialog.getDialogPane().getButtonTypes().addAll(saveBtn, ButtonType.CANCEL);

        TextField address = new TextField(c.getAddress());
        TextArea notes = new TextArea(c.getNotes());
        notes.setPrefRowCount(4);

        GridPane gp = new GridPane();
        gp.setHgap(10);
        gp.setVgap(10);
        gp.setPadding(new Insets(12));
        gp.add(new Label("Address:"), 0, 0);
        gp.add(address, 1, 0);
        gp.add(new Label("Notes:"), 0, 1);
        gp.add(notes, 1, 1);

        dialog.getDialogPane().setContent(gp);

        dialog.showAndWait().ifPresent(btn -> {
            if (btn == saveBtn) {
                try {
                    customerDao.updateCustomerAddressNotes(
                            c.getCustomerId(),
                            address.getText(),
                            notes.getText()
                    );

                    c.setAddress(address.getText());
                    c.setNotes(notes.getText());
                    table.refresh();
                    setStatus("Customer details updated.");
                } catch (RuntimeException ex) {
                    showError("Update details failed", ex);
                }
            }
        });
    }

    /* =========================
       CREDIT SETTINGS (limit + due policy + follow-up)
       ========================= */

    private void editCreditSettings() {
        Customer c = table.getSelectionModel().getSelectedItem();
        if (c == null) return;

        Dialog<ButtonType> dialog = new Dialog<>();
        dialog.setTitle("Credit Settings");
        dialog.setHeaderText("Customer: " + safe(c.getName()) + " (ID: " + c.getCustomerId() + ")");

        ButtonType saveBtn = new ButtonType("Save", ButtonBar.ButtonData.OK_DONE);
        dialog.getDialogPane().getButtonTypes().addAll(saveBtn, ButtonType.CANCEL);

        TextField creditLimit = new TextField(Long.toString(c.getCreditLimitPaise() / 100)); // show as rupees
        creditLimit.setPromptText("0 = no limit");

        TextField dueDays = new TextField(Integer.toString(c.getDueDays()));
        TextField graceDays = new TextField(Integer.toString(c.getGraceDays()));

        DatePicker follow = new DatePicker();
        try {
            if (c.getNextFollowupDate() != null && !c.getNextFollowupDate().isBlank()) {
                follow.setValue(LocalDate.parse(c.getNextFollowupDate()));
            }
        } catch (Exception ignored) {}

        TextArea followNotes = new TextArea(c.getFollowupNotes());
        followNotes.setPrefRowCount(3);

        GridPane gp = new GridPane();
        gp.setHgap(10);
        gp.setVgap(10);
        gp.setPadding(new Insets(12));
        gp.add(new Label("Credit limit (₹):"), 0, 0);
        gp.add(creditLimit, 1, 0);
        gp.add(new Label("Due days:"), 0, 1);
        gp.add(dueDays, 1, 1);
        gp.add(new Label("Grace days:"), 0, 2);
        gp.add(graceDays, 1, 2);
        gp.add(new Label("Next follow-up:"), 0, 3);
        gp.add(follow, 1, 3);
        gp.add(new Label("Follow-up notes:"), 0, 4);
        gp.add(followNotes, 1, 4);

        dialog.getDialogPane().setContent(gp);

        dialog.showAndWait().ifPresent(btn -> {
            if (btn != saveBtn) return;
            try {
                long limitPaise = parseRupeesToPaise(creditLimit.getText());
                int dd = parseIntSafe(dueDays.getText(), 30);
                int gd = parseIntSafe(graceDays.getText(), 0);
                String fDate = (follow.getValue() == null) ? null : follow.getValue().toString();

                customerDao.updateCreditPolicy(c.getCustomerId(), limitPaise, dd, gd, fDate, followNotes.getText());

                c.setCreditLimitPaise(limitPaise);
                c.setDueDays(dd);
                c.setGraceDays(gd);
                c.setNextFollowupDate(fDate);
                c.setFollowupNotes(followNotes.getText());
                table.refresh();

                setStatus("Credit settings updated.");
            } catch (Exception ex) {
                showError("Failed to update credit settings", ex);
            }
        });
    }

    private int parseIntSafe(String s, int fallback) {
        try { return Integer.parseInt(s.trim()); } catch (Exception e) { return fallback; }
    }

    private long parseRupeesToPaise(String s) {
        if (s == null) return 0;
        String t = s.trim();
        if (t.isEmpty()) return 0;
        double rupees = Double.parseDouble(t);
        if (rupees < 0) rupees = 0;
        return Math.round(rupees * 100.0);
    }

    /* =========================
       ACTIVATE / DEACTIVATE
       ========================= */

    private void toggleActive() {
        Customer c = table.getSelectionModel().getSelectedItem();
        if (c == null) return;

        int current = safeActive(c);
        boolean newState = current == 0; // if inactive -> activate

        String action = newState ? "Activate" : "Deactivate";
        Alert confirm = new Alert(Alert.AlertType.CONFIRMATION);
        confirm.setTitle(action + " Customer");
        confirm.setHeaderText(action + " customer: " + safe(c.getName()) + "?");
        confirm.setContentText(newState
                ? "Customer will be marked ACTIVE."
                : "Customer will be marked INACTIVE (recommended for closed accounts).");

        if (confirm.showAndWait().orElse(ButtonType.CANCEL) != ButtonType.OK) return;

        try {
            customerDao.setCustomerActive(c.getCustomerId(), newState);
            try { c.setIsActive(newState ? 1 : 0); } catch (Exception ignored) {}
            updateToggleActiveText(c);
            table.refresh();
            setStatus("Customer " + (newState ? "activated" : "deactivated") + ".");
        } catch (RuntimeException ex) {
            showError("Failed to update active status", ex);
        }
    }

    private void updateToggleActiveText(Customer c) {
        int a = safeActive(c);
        toggleActiveBtn.setText(a == 1 ? "Deactivate" : "Activate");
    }

    private int safeActive(Customer c) {
        try {
            return c.getIsActive();
        } catch (Exception ex) {
            return 1;
        }
    }

    /* =========================
       CALL / WHATSAPP
       ========================= */

    private void callSelected() {
        Customer c = table.getSelectionModel().getSelectedItem();
        if (c == null) return;
        String phone = digitsOnly(c.getPhone());
        if (phone.isEmpty()) {
            setStatus("No valid phone.");
            return;
        }
        openLink("tel:" + phone);
    }

    private void whatsappSelected() {
        Customer c = table.getSelectionModel().getSelectedItem();
        if (c == null) return;

        String phone = digitsOnly(c.getPhone());
        if (phone.isEmpty()) {
            setStatus("No valid phone.");
            return;
        }

        // Default: India +91. Change later if you store country code.
        openLink("https://wa.me/91" + phone);
    }

    private void openLink(String url) {
        try {
            if (!Desktop.isDesktopSupported()) {
                new Alert(Alert.AlertType.ERROR, "Desktop browse is not supported on this system.").showAndWait();
                return;
            }
            Desktop.getDesktop().browse(new URI(url));
        } catch (Exception ex) {
            showError("Failed to open link", ex);
        }
    }

    /* =========================
       HELPERS
       ========================= */

    /**
     * Lightweight table cell that truncates long text.
     * This reduces layout work (and visible lag) when selecting rows after search.
     */
    private static class TruncCell extends TableCell<Customer, String> {
        private final int max;
        private final Tooltip tip = new Tooltip();

        TruncCell(int maxChars) {
            this.max = Math.max(6, maxChars);
        }

        @Override
        protected void updateItem(String item, boolean empty) {
            super.updateItem(item, empty);
            if (empty || item == null || item.trim().isEmpty()) {
                setText(null);
                setTooltip(null);
                return;
            }
            String v = item.trim();
            if (v.length() <= max) {
                setText(v);
                setTooltip(null);
            } else {
                setText(v.substring(0, max - 1) + "…");
                tip.setText(v);
                setTooltip(tip);
            }
        }
    }

    private void showError(String title, Throwable ex) {
        if (ex != null) ex.printStackTrace();
        Alert a = new Alert(Alert.AlertType.ERROR);
        a.setTitle(title);
        a.setHeaderText(title);
        a.setContentText(ex == null ? "Unknown error" : ex.getMessage());
        a.showAndWait();
        setStatus(title + ": " + (ex == null ? "Unknown" : ex.getMessage()));
    }

    private void setStatus(String msg) {
        statusLabel.setText(msg == null ? "" : msg);
    }

    private String safe(String s) {
        return s == null ? "" : s.trim();
    }

    private String digitsOnly(String s) {
        return s == null ? "" : s.replaceAll("\\D+", "");
    }
}
