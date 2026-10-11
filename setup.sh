#!/usr/bin/env bash

set -euo pipefail

MODULE="termreader"
PDF_FIXTURE="testdata/sample.pdf"

echo "==> TermReader bootstrap"
echo "==> Working directory: $(pwd)"
echo

# =============================================================================
# Requirements
# =============================================================================

if ! command -v go >/dev/null 2>&1; then
    echo "ERROR: Go is not installed."
    exit 1
fi

if ! command -v pdftotext >/dev/null 2>&1; then
    echo "ERROR: pdftotext is required."
    echo "Install Poppler utilities, for example:"
    echo "  sudo apt install poppler-utils"
    exit 1
fi

if ! command -v pdfinfo >/dev/null 2>&1; then
    echo "ERROR: pdfinfo is required."
    exit 1
fi

if ! command -v ps2pdf >/dev/null 2>&1; then
    echo "ERROR: ps2pdf is required to generate the test PDF."
    echo
    echo "The Poppler tools you listed do not generate a PDF from text."
    echo "Install Ghostscript, which provides ps2pdf:"
    echo
    echo "  sudo apt install ghostscript"
    echo
    exit 1
fi

echo "    $(go version)"
echo "    $(pdfinfo -v 2>&1 | head -n 1)"
echo

# =============================================================================
# Safety
# =============================================================================

echo "==> Checking current directory"

if [ -f "go.mod" ] ||
   [ -d "cmd" ] ||
   [ -d "internal" ] ||
   [ -f "reader" ]; then

    echo
    echo "ERROR: this directory already looks like a Go project."
    echo
    echo "The bootstrap intentionally creates files in the CURRENT directory."
    echo "Run it from an empty directory."
    exit 1
fi

# =============================================================================
# Directories
# =============================================================================

echo "==> Creating project directories"

mkdir -p \
    cmd/reader \
    internal/document \
    internal/reader \
    internal/terminal \
    testdata

# =============================================================================
# Go module
# =============================================================================

echo "==> Initializing Go module"

go mod init "$MODULE"

# =============================================================================
# .gitignore
# =============================================================================

cat > .gitignore <<'EOF'
/reader
*.swp
*.swo
.DS_Store
EOF

# =============================================================================
# internal/document/document.go
#
# The application-level document abstraction.
# =============================================================================

cat > internal/document/document.go <<'EOF'
package document

// Document represents a readable document.
type Document interface {
	PageCount() int
	Page(pageNumber int) (Page, error)
	Close() error
}

// Page contains the content needed by the reader.
type Page struct {
	Number int
	Text   string
}
EOF

# =============================================================================
# internal/document/pdf.go
#
# pdfcpu-specific implementation.
#
# Responsibilities:
#
#   - open PDF
#   - validate PDF
#   - get page count
#   - extract one requested page
#   - receive the actual page number from pdfcpu
#   - convert the extracted content stream into readable text
#
# Nothing outside this package knows about pdfcpu.
# =============================================================================

cat > internal/document/pdf.go <<'EOF'
package document

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"unicode"

	"github.com/pdfcpu/pdfcpu/pkg/api"
	"github.com/pdfcpu/pdfcpu/pkg/pdfcpu/model"
)

type pdfDocument struct {
	path   string
	ctx    *model.Context
	closed bool
}

// Open opens and validates a PDF document.
func Open(path string) (Document, error) {
	ctx, err := api.ReadContextFile(context.Background(), path)
	if err != nil {
		return nil, fmt.Errorf("open PDF %q: %w", path, err)
	}

	if ctx.PageCount <= 0 {
		return nil, fmt.Errorf(
			"open PDF %q: document has no pages",
			path,
		)
	}

	return &pdfDocument{
		path: path,
		ctx:  ctx,
	}, nil
}

func (d *pdfDocument) PageCount() int {
	if d == nil || d.closed || d.ctx == nil {
		return 0
	}

	return d.ctx.PageCount
}

func (d *pdfDocument) Page(pageNumber int) (Page, error) {
	if d == nil || d.closed || d.ctx == nil {
		return Page{}, errors.New("document is closed")
	}

	if pageNumber < 1 || pageNumber > d.ctx.PageCount {
		return Page{}, fmt.Errorf(
			"invalid page number %d: expected 1..%d",
			pageNumber,
			d.ctx.PageCount,
		)
	}

	text, extractedPageNumber, err := d.extractPage(pageNumber)
	if err != nil {
		return Page{}, err
	}

	if extractedPageNumber != pageNumber {
		return Page{}, fmt.Errorf(
			"pdfcpu returned page %d while requesting page %d",
			extractedPageNumber,
			pageNumber,
		)
	}

	return Page{
		Number: extractedPageNumber,
		Text:   text,
	}, nil
}

func (d *pdfDocument) extractPage(
	pageNumber int,
) (string, int, error) {
	file, err := os.Open(d.path)
	if err != nil {
		return "", 0, fmt.Errorf(
			"open PDF for page %d: %w",
			pageNumber,
			err,
		)
	}
	defer file.Close()

	var (
		text         string
		extractedNum int
	)

	// Ask pdfcpu to extract ONLY this page.
	selectedPages := []string{
		strconv.Itoa(pageNumber),
	}

	err = api.ExtractContent(
		context.Background(),
		file,
		selectedPages,
		func(content io.Reader, extractedPageNumber int) error {
			data, err := io.ReadAll(content)
			if err != nil {
				return fmt.Errorf(
					"read extracted page %d: %w",
					extractedPageNumber,
					err,
				)
			}

			extractedNum = extractedPageNumber
			text = extractText(data)

			return nil
		},
		nil,
	)
	if err != nil {
		return "", 0, fmt.Errorf(
			"extract page %d: %w",
			pageNumber,
			err,
		)
	}

	if extractedNum == 0 {
		return "", 0, fmt.Errorf(
			"pdfcpu did not return page %d",
			pageNumber,
		)
	}

	return text, extractedNum, nil
}

func (d *pdfDocument) Close() error {
	if d == nil || d.closed {
		return nil
	}

	d.closed = true
	d.ctx = nil

	return nil
}

// extractText interprets common PDF text-showing operators.
//
// Supported:
//
//	(text) Tj
//	[(text) 20 (more text)] TJ
//	(text) '
//	(text) "
//
// pdfcpu performs the actual PDF parsing and gives us the page content
// stream. This function only turns common text operators into plain text.
func extractText(data []byte) string {
	var out strings.Builder

	for i := 0; i < len(data); {
		switch data[i] {
		case '(':
			text, next, ok := parsePDFString(data, i)
			if !ok {
				i++
				continue
			}

			j := skipWhitespace(data, next)

			if j < len(data) && data[j] == 'T' {
				j++
				j = skipWhitespace(data, j)

				if j < len(data) && data[j] == 'j' {
					appendText(&out, text)
					i = j + 1
					continue
				}
			}

			if j < len(data) &&
				(data[j] == '\'' || data[j] == '"') {
				appendText(&out, text)
				i = j + 1
				continue
			}

			i = next

		case '[':
			text, next, ok := parsePDFTextArray(data, i)
			if !ok {
				i++
				continue
			}

			j := skipWhitespace(data, next)

			if j+1 < len(data) &&
				data[j] == 'T' &&
				data[j+1] == 'J' {

				appendText(&out, text)
				i = j + 2
				continue
			}

			i = next

		default:
			i++
		}
	}

	return strings.TrimSpace(out.String())
}

func appendText(out *strings.Builder, text string) {
	text = strings.TrimSpace(text)

	if text == "" {
		return
	}

	if out.Len() > 0 {
		out.WriteByte('\n')
	}

	out.WriteString(text)
}

func parsePDFString(
	data []byte,
	start int,
) (string, int, bool) {
	if start >= len(data) || data[start] != '(' {
		return "", start, false
	}

	var out strings.Builder
	depth := 1

	for i := start + 1; i < len(data); i++ {
		switch data[i] {
		case '\\':
			if i+1 >= len(data) {
				return "", i, false
			}

			i++

			switch data[i] {
			case 'n':
				out.WriteByte('\n')

			case 'r':
				out.WriteByte('\r')

			case 't':
				out.WriteByte('\t')

			case 'b':
				out.WriteByte('\b')

			case 'f':
				out.WriteByte('\f')

			case '(', ')', '\\':
				out.WriteByte(data[i])

			default:
				if data[i] >= '0' && data[i] <= '7' {
					value := int(data[i] - '0')

					for count := 0; count < 2 && i+1 < len(data); count++ {
						if data[i+1] < '0' || data[i+1] > '7' {
							break
						}

						i++
						value = value*8 + int(data[i]-'0')
					}

					out.WriteByte(byte(value))
				} else {
					out.WriteByte(data[i])
				}
			}

		case '(':
			depth++
			out.WriteByte('(')

		case ')':
			depth--

			if depth == 0 {
				return decodeText(out.String()), i + 1, true
			}

			out.WriteByte(')')

		default:
			out.WriteByte(data[i])
		}
	}

	return "", len(data), false
}

func parsePDFTextArray(
	data []byte,
	start int,
) (string, int, bool) {
	if start >= len(data) || data[start] != '[' {
		return "", start, false
	}

	var parts []string

	for i := start + 1; i < len(data); {
		i = skipWhitespace(data, i)

		if i >= len(data) {
			return "", i, false
		}

		if data[i] == ']' {
			return strings.Join(parts, ""), i + 1, true
		}

		if data[i] == '(' {
			text, next, ok := parsePDFString(data, i)
			if !ok {
				return "", next, false
			}

			parts = append(parts, text)
			i = next
			continue
		}

		// TJ arrays may contain numeric spacing values.
		i++

		for i < len(data) &&
			(data[i] == '-' ||
				data[i] == '+' ||
				data[i] == '.' ||
				(data[i] >= '0' && data[i] <= '9')) {
			i++
		}
	}

	return "", len(data), false
}

func skipWhitespace(data []byte, i int) int {
	for i < len(data) {
		switch data[i] {
		case ' ', '\t', '\r', '\n', '\f', '\x00':
			i++
		default:
			return i
		}
	}

	return i
}

func decodeText(s string) string {
	// Simple UTF-16BE support for PDF strings with a BOM.
	if len(s) >= 2 && s[0] == 0xFE && s[1] == 0xFF {
		runes := make([]rune, 0, (len(s)-2)/2)

		for i := 2; i+1 < len(s); i += 2 {
			runes = append(
				runes,
				rune(uint16(s[i])<<8)|rune(s[i+1]),
			)
		}

		return string(runes)
	}

	var out strings.Builder

	for _, r := range s {
		if r == '\n' ||
			r == '\r' ||
			r == '\t' ||
			unicode.IsPrint(r) {
			out.WriteRune(r)
		}
	}

	return out.String()
}
EOF

# =============================================================================
# internal/document/document_test.go
# =============================================================================

cat > internal/document/document_test.go <<'EOF'
package document

import (
	"os"
	"strings"
	"testing"
)

func TestOpenAndPageCount(t *testing.T) {
	doc, err := Open("../../testdata/sample.pdf")
	if err != nil {
		t.Fatal(err)
	}
	defer doc.Close()

	if got := doc.PageCount(); got != 3 {
		t.Fatalf("expected 3 pages, got %d", got)
	}
}

func TestOpenMissingPDF(t *testing.T) {
	_, err := Open("../../testdata/does-not-exist.pdf")
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
	doc, err := Open("../../testdata/sample.pdf")
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
	doc, err := Open("../../testdata/sample.pdf")
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
	doc, err := Open("../../testdata/sample.pdf")
	if err != nil {
		t.Fatal(err)
	}
	defer doc.Close()

	tests := []struct {
		page int
		want string
	}{
		{1, "Page One"},
		{2, "Page Two"},
		{3, "Page Three"},
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
	doc, err := Open("../../testdata/sample.pdf")
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
EOF

# =============================================================================
# internal/reader/reader.go
# =============================================================================

cat > internal/reader/reader.go <<'EOF'
package reader

import "termreader/internal/document"

type Reader struct {
	document    document.Document
	currentPage int
}

func New(doc document.Document) *Reader {
	if doc == nil {
		panic("reader.New: nil document")
	}

	return &Reader{
		document:    doc,
		currentPage: 1,
	}
}

func (r *Reader) PageCount() int {
	return r.document.PageCount()
}

func (r *Reader) CurrentPageNumber() int {
	return r.currentPage
}

func (r *Reader) CurrentPage() (document.Page, error) {
	return r.document.Page(r.currentPage)
}

func (r *Reader) Next() {
	if r.currentPage < r.PageCount() {
		r.currentPage++
	}
}

func (r *Reader) Previous() {
	if r.currentPage > 1 {
		r.currentPage--
	}
}
EOF

# =============================================================================
# internal/reader/reader_test.go
# =============================================================================

cat > internal/reader/reader_test.go <<'EOF'
package reader

import (
	"errors"
	"testing"

	"termreader/internal/document"
)

type fakeDocument struct {
	pages []document.Page
}

func (f *fakeDocument) PageCount() int {
	return len(f.pages)
}

func (f *fakeDocument) Page(pageNumber int) (document.Page, error) {
	if pageNumber < 1 || pageNumber > len(f.pages) {
		return document.Page{}, errors.New("invalid page")
	}

	return f.pages[pageNumber-1], nil
}

func (f *fakeDocument) Close() error {
	return nil
}

func newFakeDocument() *fakeDocument {
	return &fakeDocument{
		pages: []document.Page{
			{Number: 1, Text: "Page One"},
			{Number: 2, Text: "Page Two"},
			{Number: 3, Text: "Page Three"},
		},
	}
}

func TestNewStartsAtPageOne(t *testing.T) {
	r := New(newFakeDocument())

	if got := r.CurrentPageNumber(); got != 1 {
		t.Fatalf("expected page 1, got %d", got)
	}

	if got := r.PageCount(); got != 3 {
		t.Fatalf("expected 3 pages, got %d", got)
	}
}

func TestNext(t *testing.T) {
	r := New(newFakeDocument())

	r.Next()

	if got := r.CurrentPageNumber(); got != 2 {
		t.Fatalf("expected page 2, got %d", got)
	}

	r.Next()

	if got := r.CurrentPageNumber(); got != 3 {
		t.Fatalf("expected page 3, got %d", got)
	}

	r.Next()

	if got := r.CurrentPageNumber(); got != 3 {
		t.Fatalf("expected to remain on page 3, got %d", got)
	}
}

func TestPrevious(t *testing.T) {
	r := New(newFakeDocument())

	r.Next()
	r.Next()

	r.Previous()

	if got := r.CurrentPageNumber(); got != 2 {
		t.Fatalf("expected page 2, got %d", got)
	}

	r.Previous()

	if got := r.CurrentPageNumber(); got != 1 {
		t.Fatalf("expected page 1, got %d", got)
	}

	r.Previous()

	if got := r.CurrentPageNumber(); got != 1 {
		t.Fatalf("expected to remain on page 1, got %d", got)
	}
}

func TestCurrentPage(t *testing.T) {
	r := New(newFakeDocument())

	page, err := r.CurrentPage()
	if err != nil {
		t.Fatal(err)
	}

	if page.Number != 1 {
		t.Fatalf("expected page 1, got %d", page.Number)
	}

	r.Next()

	page, err = r.CurrentPage()
	if err != nil {
		t.Fatal(err)
	}

	if page.Number != 2 {
		t.Fatalf("expected page 2, got %d", page.Number)
	}
}
EOF

# =============================================================================
# internal/terminal/terminal.go
# =============================================================================

cat > internal/terminal/terminal.go <<'EOF'
package terminal

import (
	"bufio"
	"fmt"
	"io"
	"strings"

	"termreader/internal/reader"
)

type Terminal struct {
	reader *reader.Reader
	input  io.Reader
	output io.Writer
}

func New(
	r *reader.Reader,
	input io.Reader,
	output io.Writer,
) *Terminal {
	return &Terminal{
		reader: r,
		input:  input,
		output: output,
	}
}

func (t *Terminal) Run(filename string) error {
	if err := t.render(filename); err != nil {
		return err
	}

	scanner := bufio.NewScanner(t.input)

	for scanner.Scan() {
		switch strings.ToLower(strings.TrimSpace(scanner.Text())) {
		case "n", "next", "right":
			t.reader.Next()

		case "p", "previous", "left":
			t.reader.Previous()

		case "q", "quit":
			return nil

		default:
			continue
		}

		if err := t.render(filename); err != nil {
			return err
		}
	}

	return scanner.Err()
}

func (t *Terminal) render(filename string) error {
	page, err := t.reader.CurrentPage()
	if err != nil {
		return err
	}

	fmt.Fprint(t.output, "\033[H\033[2J")

	fmt.Fprintln(t.output, "TermReader")
	fmt.Fprintln(t.output)
	fmt.Fprintln(t.output, filename)
	fmt.Fprintln(t.output)

	fmt.Fprintf(
		t.output,
		"Page %d / %d\n\n",
		t.reader.CurrentPageNumber(),
		t.reader.PageCount(),
	)

	fmt.Fprintln(t.output, page.Text)
	fmt.Fprintln(t.output)
	fmt.Fprintln(t.output, "[n] next  [p] previous  [q] quit")

	return nil
}
EOF

# =============================================================================
# cmd/reader/main.go
# =============================================================================

cat > cmd/reader/main.go <<'EOF'
package main

import (
	"fmt"
	"os"
	"path/filepath"

	"termreader/internal/document"
	"termreader/internal/reader"
	"termreader/internal/terminal"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: reader <book.pdf>")
		os.Exit(2)
	}

	path := os.Args[1]

	doc, err := document.Open(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	defer func() {
		if err := doc.Close(); err != nil {
			fmt.Fprintln(os.Stderr, "close PDF:", err)
		}
	}()

	r := reader.New(doc)

	app := terminal.New(
		r,
		os.Stdin,
		os.Stdout,
	)

	if err := app.Run(filepath.Base(path)); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
EOF

# =============================================================================
# Generate test PDF
#
# We create PostScript, then use ps2pdf.
#
# pdftotext/pdfinfo are then used below to verify the generated PDF.
# =============================================================================

echo "==> Generating test PDF"

cat > testdata/sample.ps <<'EOF'
%!PS-Adobe-3.0
%%Pages: 3
%%BoundingBox: 0 0 595 842
%%EndComments

/Helvetica-Bold findfont
24 scalefont
setfont

%%Page: 1 1
72 760 moveto
(Page One) show

/Helvetica findfont
14 scalefont
setfont

72 720 moveto
(This is page one of the TermReader test document.) show
showpage

%%Page: 2 2
/Helvetica-Bold findfont
24 scalefont
setfont

72 760 moveto
(Page Two) show

/Helvetica findfont
14 scalefont
setfont

72 720 moveto
(This is page two of the TermReader test document.) show
showpage

%%Page: 3 3
/Helvetica-Bold findfont
24 scalefont
setfont

72 760 moveto
(Page Three) show

/Helvetica findfont
14 scalefont
setfont

72 720 moveto
(This is page three of the TermReader test document.) show
showpage

%%EOF
EOF

ps2pdf testdata/sample.ps "$PDF_FIXTURE"

rm -f testdata/sample.ps

# =============================================================================
# Verify fixture using Poppler
# =============================================================================

echo "==> Checking generated PDF"

PAGE_COUNT="$(pdfinfo "$PDF_FIXTURE" | awk '/^Pages:/ { print $2 }')"

if [ "$PAGE_COUNT" != "3" ]; then
    echo "ERROR: expected 3 PDF pages, got ${PAGE_COUNT:-unknown}"
    exit 1
fi

echo "    PDF pages: $PAGE_COUNT"

echo "==> Checking PDF text with pdftotext"

pdftotext "$PDF_FIXTURE" /tmp/termreader-sample.txt

grep -q "Page One" /tmp/termreader-sample.txt
grep -q "Page Two" /tmp/termreader-sample.txt
grep -q "Page Three" /tmp/termreader-sample.txt

rm -f /tmp/termreader-sample.txt

echo "    PDF text looks correct"

# =============================================================================
# pdfcpu
# =============================================================================

echo "==> Adding pdfcpu"

go get github.com/pdfcpu/pdfcpu@v0.16.0

echo "==> Tidying modules"

go mod tidy

# =============================================================================
# Format
# =============================================================================

echo "==> Formatting Go code"

gofmt -w \
    cmd/reader/main.go \
    internal/document/document.go \
    internal/document/pdf.go \
    internal/document/document_test.go \
    internal/reader/reader.go \
    internal/reader/reader_test.go \
    internal/terminal/terminal.go

# =============================================================================
# Tests
# =============================================================================

echo
echo "==> Running tests"

go test ./...

# =============================================================================
# Build
# =============================================================================

echo
echo "==> Building application"

go build -o reader ./cmd/reader

# =============================================================================
# Smoke test
# =============================================================================

echo
echo "==> Running smoke test"

./reader testdata/sample.pdf </dev/null >/tmp/termreader-smoke.txt

grep -q "Page 1 / 3" /tmp/termreader-smoke.txt
grep -q "Page One" /tmp/termreader-smoke.txt

rm -f /tmp/termreader-smoke.txt

# =============================================================================
# Done
# =============================================================================

echo
echo "============================================================"
echo "TermReader created successfully"
echo "============================================================"
echo
echo "Current directory:"
echo "  $(pwd)"
echo
echo "Structure:"
echo
echo "  cmd/"
echo "    reader/"
echo "      main.go"
echo
echo "  internal/"
echo "    document/"
echo "      document.go"
echo "      pdf.go"
echo "      document_test.go"
echo
echo "    reader/"
echo "      reader.go"
echo "      reader_test.go"
echo
echo "    terminal/"
echo "      terminal.go"
echo
echo "  testdata/"
echo "    sample.pdf"
echo
echo "  go.mod"
echo "  go.sum"
echo "  .gitignore"
echo
echo "Run:"
echo "  ./reader testdata/sample.pdf"
echo
echo "Controls:"
echo "  n + Enter    next page"
echo "  p + Enter    previous page"
echo "  q + Enter    quit"
echo
echo "Tests:"
echo "  go test ./..."
echo
echo "Build:"
echo "  go build ./..."
echo