package com.gasstation.app;

import com.gasstation.app.dao.CustomerDao;
import com.gasstation.app.dao.ReminderDao;
import com.gasstation.app.model.Customer;
import com.gasstation.app.model.CustomerKpi;
import com.gasstation.app.service.CustomerKpiService;
import com.gasstation.app.service.ReminderTemplateService;
import com.gasstation.app.service.ReminderTemplateService.Lang;
import com.gasstation.app.service.ReminderTemplateService.TemplateKey;
import javafx.beans.property.SimpleStringProperty;
import javafx.collections.FXCollections;
import javafx.collections.ObservableList;
import javafx.geometry.Insets;
import javafx.scene.control.*;
import javafx.scene.layout.*;

import java.awt.Desktop;
import java.net.URI;
import java.sql.SQLException;
import java.time.LocalDate;
import java.util.Comparator;
import java.util.List;
import java.util.stream.Collectors;

public class RemindersScreen extends BorderPane {

    private final AppNavigator nav;

    private final CustomerDao customerDao = new CustomerDao();
    private final ReminderDao reminderDao = new ReminderDao();
    private final CustomerKpiService kpiService = new CustomerKpiService();
    private final ReminderTemplateService templateService = new ReminderTemplateService();

    private final TableView<CustomerKpi> table = new TableView<>();
    private final ObservableList<CustomerKpi> data = FXCollections.observableArrayList();

    private final ComboBox<TemplateKey> templateBox = new ComboBox<>();
    private final ComboBox<Lang> langBox = new ComboBox<>();

    private final TextArea messageArea = new TextArea();
    private final Label statusLbl = new Label(" ");

    public RemindersScreen(AppNavigator nav) {
        this.nav = nav;
        setPadding(new Insets(10));

        setTop(buildTopBar());
        setCenter(buildCenter());
        setBottom(buildBottom());

        refresh();
    }

    private Pane buildTopBar() {
        Label title = new Label("Reminders");
        title.setStyle("-fx-font-size: 16px; -fx-font-weight: bold;");

        Button refreshBtn = new Button("Refresh");
        refreshBtn.setOnAction(e -> refresh());

        templateBox.getItems().setAll(TemplateKey.AUTO, TemplateKey.GENTLE, TemplateKey.OVERDUE, TemplateKey.FINAL);
        templateBox.setValue(TemplateKey.AUTO);
        templateBox.setOnAction(e -> loadTemplateForSelected());

        langBox.getItems().setAll(Lang.EN, Lang.TE);
        langBox.setValue(templateService.getDefaultLang());
        langBox.setOnAction(e -> loadTemplateForSelected());

        Region spacer = new Region();
        HBox.setHgrow(spacer, Priority.ALWAYS);

        HBox bar = new HBox(10, title, spacer,
                new Label("Template:"), templateBox,
                new Label("Lang:"), langBox,
                refreshBtn);
        bar.setPadding(new Insets(0, 0, 10, 0));
        return bar;
    }

    private Pane buildCenter() {
        configureTable();

        messageArea.setPromptText("Message preview...");
        messageArea.setWrapText(true);
        messageArea.setPrefRowCount(6);

        Button waBtn = new Button("Send WhatsApp + Log");
        waBtn.setMaxWidth(Double.MAX_VALUE);
        waBtn.setOnAction(e -> sendWhatsAppAndLog());

        Button followupBtn = new Button("Set next follow-up (from settings)");
        followupBtn.setMaxWidth(Double.MAX_VALUE);
        followupBtn.setOnAction(e -> setFollowupUsingSettings());

        Button copyBtn = new Button("Copy Message");
        copyBtn.setMaxWidth(Double.MAX_VALUE);
        copyBtn.setOnAction(e -> {
            String msg = messageArea.getText() == null ? "" : messageArea.getText().trim();
            if (msg.isEmpty()) return;
            javafx.scene.input.ClipboardContent cc = new javafx.scene.input.ClipboardContent();
            cc.putString(msg);
            javafx.scene.input.Clipboard.getSystemClipboard().setContent(cc);
            statusLbl.setText("Copied message to clipboard");
        });

        VBox right = new VBox(10,
                new Label("Message"),
                messageArea,
                copyBtn,
                waBtn,
                followupBtn
        );
        right.setPadding(new Insets(0, 0, 0, 10));
        VBox.setVgrow(messageArea, Priority.ALWAYS);

        HBox center = new HBox(10, table, right);
        HBox.setHgrow(table, Priority.ALWAYS);
        HBox.setHgrow(right, Priority.NEVER);
        table.setPrefWidth(650);

        return center;
    }

    private Pane buildBottom() {
        HBox box = new HBox(statusLbl);
        box.setPadding(new Insets(10, 0, 0, 0));
        return box;
    }

    private void configureTable() {
        table.setColumnResizePolicy(TableView.CONSTRAINED_RESIZE_POLICY);

        TableColumn<CustomerKpi, String> name = new TableColumn<>("Customer");
        name.setCellValueFactory(d -> new SimpleStringProperty(
                d.getValue().getCustomer() == null ? "" : d.getValue().getCustomer().getName()
        ));

        TableColumn<CustomerKpi, String> phone = new TableColumn<>("Phone");
        phone.setCellValueFactory(d -> new SimpleStringProperty(
                d.getValue().getCustomer() == null ? "" : d.getValue().getCustomer().getPhone()
        ));

        TableColumn<CustomerKpi, String> overdueAmt = new TableColumn<>("Overdue");
        overdueAmt.setCellValueFactory(d -> new SimpleStringProperty(
                com.gasstation.app.util.MoneyUtil.formatMoney(d.getValue().getOverdueAmountPaise())
        ));

        TableColumn<CustomerKpi, String> days = new TableColumn<>("Days");
        days.setCellValueFactory(d -> new SimpleStringProperty(
                Integer.toString(d.getValue().getMaxDaysOverdue())
        ));

        TableColumn<CustomerKpi, String> risk = new TableColumn<>("Risk");
        risk.setCellValueFactory(d -> new SimpleStringProperty(
                d.getValue().getRiskTag() == null ? "" : d.getValue().getRiskTag()
        ));

        table.getColumns().setAll(java.util.List.of(name, phone, overdueAmt, days, risk));
        table.setItems(data);

        table.getSelectionModel().selectedItemProperty().addListener((obs, oldV, newV) -> loadTemplateForSelected());

        // double click -> ledger
        table.setRowFactory(tv -> {
            TableRow<CustomerKpi> row = new TableRow<>();
            row.setOnMouseClicked(e -> {
                if (e.getClickCount() == 2 && !row.isEmpty()) {
                    CustomerKpi k = row.getItem();
                    if (k != null && k.getCustomer() != null) nav.showLedger(k.getCustomer());
                }
            });
            return row;
        });
    }

    private void refresh() {
        try {
            statusLbl.setText("Loading...");
            List<Customer> customers = customerDao.listAll();

            List<CustomerKpi> kpis = kpiService.buildForCustomers(customers)
                    .stream()
                    .filter(k -> k.getCustomer() != null)
                    .filter(k -> k.getCustomer().getIsActive() == 1)
                    .filter(k -> k.getOverdueAmountPaise() > 0)
                    .sorted(Comparator.comparingInt(CustomerKpi::getMaxDaysOverdue).reversed())
                    .collect(Collectors.toList());

            data.setAll(kpis);

            if (!data.isEmpty()) {
                table.getSelectionModel().select(0);
            } else {
                messageArea.clear();
            }

            statusLbl.setText("Queue: " + data.size() + " overdue customer(s)");
        } catch (SQLException e) {
            statusLbl.setText("Error: " + e.getMessage());
            new Alert(Alert.AlertType.ERROR, "Failed to load reminders\n\n" + e.getMessage()).showAndWait();
        }
    }

    private void loadTemplateForSelected() {
        CustomerKpi k = table.getSelectionModel().getSelectedItem();
        if (k == null) {
            messageArea.clear();
            return;
        }

        TemplateKey tk = templateBox.getValue() == null ? TemplateKey.AUTO : templateBox.getValue();
        Lang lang = langBox.getValue() == null ? templateService.getDefaultLang() : langBox.getValue();

        TemplateKey effective = (tk == TemplateKey.AUTO) ? templateService.autoPick(k.getMaxDaysOverdue()) : tk;
        String msg = templateService.render(effective, lang, k);

        messageArea.setText(msg);
    }

    private void sendWhatsAppAndLog() {
        CustomerKpi k = table.getSelectionModel().getSelectedItem();
        if (k == null) return;

        Customer c = k.getCustomer();
        if (c == null) return;

        String phone = c.getPhone();
        String msg = messageArea.getText() == null ? "" : messageArea.getText().trim();
        if (msg.isEmpty()) {
            new Alert(Alert.AlertType.WARNING, "Message is empty.").showAndWait();
            return;
        }

        try {
            // WhatsApp web expects country code; default +91 if 10 digits.
            String to = phone;
            if (to != null && to.length() == 10) to = "91" + to;

            String url = "https://wa.me/" + to + "?text=" + java.net.URLEncoder.encode(msg, "UTF-8");
            if (Desktop.isDesktopSupported()) {
                Desktop.getDesktop().browse(new URI(url));
            }

            TemplateKey tk = templateBox.getValue() == null ? TemplateKey.AUTO : templateBox.getValue();
            TemplateKey effective = (tk == TemplateKey.AUTO) ? templateService.autoPick(k.getMaxDaysOverdue()) : tk;

            reminderDao.insert(
                    c.getCustomerId(),
                    LocalDate.now().toString(),
                    k.getMaxDaysOverdue(),
                    k.getOverdueAmountPaise(),
                    effective.name(),
                    msg,
                    "WHATSAPP",
                    null
            );

            statusLbl.setText("Sent + logged reminder for " + c.getName());
        } catch (Exception e) {
            new Alert(Alert.AlertType.ERROR, "Failed to send/log\n\n" + e.getMessage()).showAndWait();
        }
    }

    private void setFollowupUsingSettings() {
        CustomerKpi k = table.getSelectionModel().getSelectedItem();
        if (k == null) return;

        Customer c = k.getCustomer();
        if (c == null) return;

        int days = templateService.getFollowupDaysOrDefault(7);
        if (days < 0) days = 0;
        if (days > 3650) days = 3650;

        try {
            customerDao.updateFollowup(
                    c.getCustomerId(),
                    LocalDate.now().plusDays(days).toString(),
                    "Follow up for overdue payment"
            );
            statusLbl.setText("Follow-up set +" + days + " days for " + c.getName());
        } catch (Exception e) {
            new Alert(Alert.AlertType.ERROR, "Failed to set follow-up\n\n" + e.getMessage()).showAndWait();
        }
    }
}
