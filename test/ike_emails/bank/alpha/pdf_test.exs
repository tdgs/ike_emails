defmodule IkeEmails.Bank.Alpha.PdfTest do
  use ExUnit.Case, async: true

  alias IkeEmails.Bank.Alpha.Pdf

  describe "decode/1" do
    test "decodes a PDF whose size is the one sent with it" do
      # "%PDF-" in base64
      assert Pdf.decode(%{bytes: 5, base64: "JVBERi0="}) == {:ok, "%PDF-"}
    end

    test "decodes the bytes of a whole file" do
      pdf = "%PDF-1.4\n" <> :binary.copy(<<0, 255, 10, 13>>, 1000) <> "\n%%EOF\n"

      assert Pdf.decode(%{bytes: byte_size(pdf), base64: Base.encode64(pdf)}) == {:ok, pdf}
    end

    test "fails when the content is not of the size sent with it" do
      assert Pdf.decode(%{bytes: 6, base64: "JVBERi0="}) == {:error, :invalid_pdf}
      assert Pdf.decode(%{bytes: 4, base64: "JVBERi0="}) == {:error, :invalid_pdf}
      assert Pdf.decode(%{bytes: 0, base64: "JVBERi0="}) == {:error, :invalid_pdf}
    end

    test "fails when the content is no base64" do
      assert Pdf.decode(%{bytes: 5, base64: "%PDF-"}) == {:error, :invalid_pdf}
      assert Pdf.decode(%{bytes: 5, base64: "JVBERi0"}) == {:error, :invalid_pdf}
      assert Pdf.decode(%{bytes: 5, base64: "JVBE Ri0="}) == {:error, :invalid_pdf}
    end

    test "fails when the content does not start like a PDF" do
      html = "<html>"

      assert Pdf.decode(%{bytes: byte_size(html), base64: Base.encode64(html)}) ==
               {:error, :invalid_pdf}

      assert Pdf.decode(%{bytes: 0, base64: ""}) == {:error, :invalid_pdf}
      assert Pdf.decode(%{bytes: 4, base64: Base.encode64("%PDF")}) == {:error, :invalid_pdf}
    end

    test "fails for anything else than the size and the content" do
      assert Pdf.decode(%{bytes: 5}) == {:error, :invalid_pdf}
      assert Pdf.decode(%{base64: "JVBERi0="}) == {:error, :invalid_pdf}
      assert Pdf.decode(%{bytes: "5", base64: "JVBERi0="}) == {:error, :invalid_pdf}
      assert Pdf.decode(%{bytes: 5, base64: nil}) == {:error, :invalid_pdf}
      assert Pdf.decode(%{bytes: 5.0, base64: "JVBERi0="}) == {:error, :invalid_pdf}
      assert Pdf.decode(%{"bytes" => 5, "base64" => "JVBERi0="}) == {:error, :invalid_pdf}
      assert Pdf.decode("%PDF-1.4") == {:error, :invalid_pdf}
      assert Pdf.decode(nil) == {:error, :invalid_pdf}
    end
  end
end
