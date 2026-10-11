package terminal

import (
	"bufio"
	"fmt"
	"io"
	"strconv"
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
		input := strings.TrimSpace(scanner.Text())
		switch cmd := strings.ToLower(input); cmd {
		case "n", "next", "right":
			t.reader.Next()

		case "p", "previous", "left":
			t.reader.Previous()

		case "q", "quit":
			return nil

		default:
			// try parsing as a page number
			if num, err := strconv.Atoi(input); err == nil {
				if err := t.reader.GoToPage(num); err != nil {
					fmt.Fprintln(t.output, err)
				}
			} else {
				continue
			}
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

	fmt.Fprintln(t.output)
	fmt.Fprintln(t.output, filename)
	fmt.Fprintln(t.output)

	fmt.Fprintf(
		t.output,
		"Page %d / %d\n\n",
		t.reader.CurrentPageNumber(),
		t.reader.PageCount(),
	)

	fmt.Fprintln(t.output, page.Layout)
	fmt.Fprintln(t.output)
	fmt.Fprintln(t.output, "[n] next  [p] previous  [q] quit")

	return nil
}
