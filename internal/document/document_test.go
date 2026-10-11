package document

import (
	"os"
	"strings"
	"testing"
)

func TestOpenAndPageCount(t *testing.T) {
	doc, err := Open("../../fixtures/sample.pdf")
	if err != nil {
		t.Fatal(err)
	}
	defer doc.Close()

	if got := doc.PageCount(); got != 3 {
		t.Fatalf("expected 3 pages, got %d", got)
	}
}

func TestOpenMissingPDF(t *testing.T) {
	_, err := Open("../../fixtures/does-not-exist.pdf")
	if err == nil {
		t.Fatal("expected an error")
	}

	if !strings.Contains(err.Error(), "open PDF") {
		t.Fatalf("expected contextual error, got %q", err)
	}
}

func TestOpenInvalidPDF(t *testing.T) {
	path := t.TempDir() + "/invalid.pdf"

	if err := os.WriteFile(
		path,
		[]byte("not a PDF"),
		0644,
	); err != nil {
		t.Fatal(err)
	}

	_, err := Open(path)
	if err == nil {
		t.Fatal("expected an error")
	}
}

func TestPageRetrieval(t *testing.T) {
	doc, err := Open("../../fixtures/sample.pdf")
	if err != nil {
		t.Fatal(err)
	}
	defer doc.Close()

	for pageNumber := 1; pageNumber <= 3; pageNumber++ {
		page, err := doc.Page(pageNumber)
		if err != nil {
			t.Fatalf("Page(%d): %v", pageNumber, err)
		}

		if page.Number != pageNumber {
			t.Fatalf(
				"expected page number %d, got %d",
				pageNumber,
				page.Number,
			)
		}
	}
}

func TestPageBounds(t *testing.T) {
	doc, err := Open("../../fixtures/sample.pdf")
	if err != nil {
		t.Fatal(err)
	}
	defer doc.Close()

	for _, pageNumber := range []int{0, -1, 4} {
		if _, err := doc.Page(pageNumber); err == nil {
			t.Fatalf("expected Page(%d) to fail", pageNumber)
		}
	}
}

func TestPageText(t *testing.T) {
	doc, err := Open("../../fixtures/sample.pdf")
	if err != nil {
		t.Fatal(err)
	}
	defer doc.Close()

	tests := []struct {
		page int
		want string
	}{
		{1, "Arrays and Linke"},
		{2, "Working with Data"},
		{3, "A Final Layout Check"},
	}

	for _, tt := range tests {
		page, err := doc.Page(tt.page)
		if err != nil {
			t.Fatalf("Page(%d): %v", tt.page, err)
		}

		if !strings.Contains(page.Text, tt.want) {
			t.Fatalf(
				"page %d text does not contain %q: %q",
				tt.page,
				tt.want,
				page.Text,
			)
		}
	}
}

func TestClose(t *testing.T) {
	doc, err := Open("../../fixtures/sample.pdf")
	if err != nil {
		t.Fatal(err)
	}

	if err := doc.Close(); err != nil {
		t.Fatal(err)
	}

	if _, err := doc.Page(1); err == nil {
		t.Fatal("expected Page after Close to fail")
	}
}
