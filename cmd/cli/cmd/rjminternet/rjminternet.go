package rjminternet

import (
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/cavaliercoder/grab"
)

func DownloadFile(filepath string, url string) error {
	// create client
	client := grab.NewClient()
	req, _ := grab.NewRequest(filepath, url)

	// start download
	fmt.Printf("Downloading %v...\n", req.URL())
	resp := client.Do(req)
	fmt.Printf("  %v\n", resp.HTTPResponse.Status)

	// start UI loop
	t := time.NewTicker(500 * time.Millisecond)
	defer t.Stop()

Loop:
	for {
		select {
		case <-t.C:
			sProg := fmt.Sprintf("%.1f", 100*resp.Progress())
			//fmt.Println(sProg + "% complete...")
			fmt.Printf("\r" + sProg + "%% complete...")

		case <-resp.Done:
			// download is complete
			break Loop
		}
	}

	// check for errors
	if err := resp.Err(); err != nil {
		fmt.Fprintf(os.Stderr, "Download failed: %v\n", err)
		return err
	}

	fmt.Printf("Download saved to %v \n", resp.Filename)

	return nil
}

func WebIsReachable() bool {
	response, err := http.Get("https://www.google.com")

	if err != nil {
		return false
	}

	if response.StatusCode == 200 {
		return true
	}

	return false
}
