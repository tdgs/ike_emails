defmodule IkeEmails.Bank.Alpha.LoginTest do
  use ExUnit.Case, async: true

  alias IkeEmails.Bank.Alpha.Login

  describe "session_in_use?/1" do
    test "is true for what the login page shows when the bank ends the session in use" do
      message =
        "Η συνδρομή σας χρησιμοποιείται ήδη, πιθανώς από άλλο υπολογιστή. Για την ασφάλειά σας διακόψαμε την ενεργή σύνδεση. Παρακαλούμε επιχειρήστε νέα σύνδεση και ελέγξτε τις συναλλαγές χρησιμοποιώντας τις επιλογές ερωτήσεων (λογαριασμών, μεταφορών και πληρωμών). Επίσης, σας συνιστούμε όπως προβείτε στην αλλαγή του μυστικού σας κωδικού."

      assert Login.session_in_use?(message)
    end

    test "is true for the phrase alone, wherever it is" do
      assert Login.session_in_use?("χρησιμοποιείται ήδη")
      assert Login.session_in_use?("x χρησιμοποιείται ήδη y")
    end

    test "is false for any other error of the login page" do
      refute Login.session_in_use?("Τα στοιχεία που δώσατε δεν είναι σωστά.")
      refute Login.session_in_use?("Your account is already in use")
      refute Login.session_in_use?("χρησιμοποιείται")
      refute Login.session_in_use?("")
    end

    test "is false for what is no text" do
      refute Login.session_in_use?(nil)
    end
  end
end
