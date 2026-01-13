package com.gasstation.app;

import com.gasstation.app.db.Db;
import javafx.application.Application;
import javafx.stage.Stage;

public class App extends Application {

	@Override
	public void start(Stage stage) {
	    System.out.println("START() ENTERED");
	    stage.setTitle("Credit Accounting");

	    AppNavigator nav = new AppNavigator(stage);
	    System.out.println("NAV CREATED");

	    nav.start();
	    System.out.println("NAV STARTED");

	    stage.show();
	    System.out.println("STAGE SHOWN");


	}



    public static void main(String[] args) {
        Db.init();
        launch(args);
    }
    
    
}
