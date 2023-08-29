package main

import (
	"encoding/json"
	"fmt"
	"io"

	"github.com/mholt/archiver/v3"

	"log"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"time"

	be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/rjminternet"
)

type githubInfo struct {
	URL       string `json:"url"`
	AssetsURL string `json:"assets_url"`
	UploadURL string `json:"upload_url"`
	HTMLURL   string `json:"html_url"`
	ID        int    `json:"id"`
	Author    struct {
		Login             string `json:"login"`
		ID                int    `json:"id"`
		NodeID            string `json:"node_id"`
		AvatarURL         string `json:"avatar_url"`
		GravatarID        string `json:"gravatar_id"`
		URL               string `json:"url"`
		HTMLURL           string `json:"html_url"`
		FollowersURL      string `json:"followers_url"`
		FollowingURL      string `json:"following_url"`
		GistsURL          string `json:"gists_url"`
		StarredURL        string `json:"starred_url"`
		SubscriptionsURL  string `json:"subscriptions_url"`
		OrganizationsURL  string `json:"organizations_url"`
		ReposURL          string `json:"repos_url"`
		EventsURL         string `json:"events_url"`
		ReceivedEventsURL string `json:"received_events_url"`
		Type              string `json:"type"`
		SiteAdmin         bool   `json:"site_admin"`
	} `json:"author"`
	NodeID          string    `json:"node_id"`
	TagName         string    `json:"tag_name"`
	TargetCommitish string    `json:"target_commitish"`
	Name            string    `json:"name"`
	Draft           bool      `json:"draft"`
	Prerelease      bool      `json:"prerelease"`
	CreatedAt       time.Time `json:"created_at"`
	PublishedAt     time.Time `json:"published_at"`
	Assets          []struct {
		URL      string `json:"url"`
		ID       int    `json:"id"`
		NodeID   string `json:"node_id"`
		Name     string `json:"name"`
		Label    string `json:"label"`
		Uploader struct {
			Login             string `json:"login"`
			ID                int    `json:"id"`
			NodeID            string `json:"node_id"`
			AvatarURL         string `json:"avatar_url"`
			GravatarID        string `json:"gravatar_id"`
			URL               string `json:"url"`
			HTMLURL           string `json:"html_url"`
			FollowersURL      string `json:"followers_url"`
			FollowingURL      string `json:"following_url"`
			GistsURL          string `json:"gists_url"`
			StarredURL        string `json:"starred_url"`
			SubscriptionsURL  string `json:"subscriptions_url"`
			OrganizationsURL  string `json:"organizations_url"`
			ReposURL          string `json:"repos_url"`
			EventsURL         string `json:"events_url"`
			ReceivedEventsURL string `json:"received_events_url"`
			Type              string `json:"type"`
			SiteAdmin         bool   `json:"site_admin"`
		} `json:"uploader"`
		ContentType        string    `json:"content_type"`
		State              string    `json:"state"`
		Size               int       `json:"size"`
		DownloadCount      int       `json:"download_count"`
		CreatedAt          time.Time `json:"created_at"`
		UpdatedAt          time.Time `json:"updated_at"`
		BrowserDownloadURL string    `json:"browser_download_url"`
	} `json:"assets"`
	TarballURL string `json:"tarball_url"`
	ZipballURL string `json:"zipball_url"`
	Body       string `json:"body"`
}

func main() {
	fmt.Println(be.CUpdaterAppName + " v" + be.CBWAppVersion + " Started...")

	ex, err := os.Executable()
	if err != nil {
		log.Fatal("unable to retrieve running binary: ", err)
	}
	dir := be.AddTrailingSlash(filepath.Dir(ex))
	tmpDir := dir + be.AddTrailingSlash("tmp")

	var url, compressedFN, bwFile string

	// Get download compressedFN link
	sTag, err := getLatestVersionTag()
	if err != nil {
		log.Fatal("Unable to getLatestVersionTag " + err.Error())
	}

	fmt.Println("Latest release detected is: " + sTag)

	// example link https://github.com/richardltc/boxwallet/releases/download/0.61.0/boxwallet_0.61.0_Linux_64bit.tar.gz
	url = "https://github.com/richardltc/boxwallet/releases/download/" + sTag + "/"

	switch runtime.GOOS {
	case "darwin":
		compressedFN = "boxwallet_" + sTag + "_macOS_64bit.tar.gz"
		bwFile = be.CAppFilename
	case "windows":
		compressedFN = "boxwallet_" + sTag + "_Windows_64bit.zip"
		bwFile = be.CAppFilenameWin
	case "linux":
		bwFile = be.CAppFilename
		switch runtime.GOARCH {
		case "386":
			compressedFN = "boxwallet_" + sTag + "_Linux_32bit.tar.gz"
		case "arm":
			compressedFN = "boxwallet_" + sTag + "_Linux_arm32bit.tar.gz"
		case "arm64":
			compressedFN = "boxwallet_" + sTag + "_Linux_arm64.tar.gz"
		case "amd64":
			compressedFN = "boxwallet_" + sTag + "_Linux_64bit.tar.gz"
		default:
			log.Fatal("Unable to determine GOARCH type")
		}
	default:
		log.Fatal("Unable to determine OS type")
	}

	// Download the compressedFN
	if err := rjminternet.DownloadFile(dir, url+compressedFN); err != nil {
		log.Fatal("unable to download compressedFN: ", url+compressedFN, err)
	}
	defer os.RemoveAll(dir + compressedFN)

	if err := archiver.Unarchive(dir+compressedFN, tmpDir); err != nil {
		log.Fatal("unable to un-archive compressedFN: ", err)
	}
	defer os.RemoveAll(tmpDir)

	// Copy README.md
	if err := be.FileCopy(tmpDir+"README.md", dir+"README.md", false); err != nil {
		log.Fatal("Unable to copy "+tmpDir+"README.md"+" to "+dir+"README.md"+": ", err)
	}

	// Backup existing boxwallet file
	fmt.Println("Attempting backup of existing " + be.CAppName + " file...")
	if err := be.BackupFile(dir, bwFile, dir, "", false); err != nil {
		log.Fatal("Unable to copy to backup : ", err)
	}

	// Copy boxwallet
	if err := be.FileCopy(tmpDir+bwFile, dir+bwFile, false); err != nil {
		log.Fatal("Unable to copy "+tmpDir+bwFile+" to "+dir+bwFile+": ", err)
	}

	fmt.Println("Updating permissions on new " + be.CAppName + " file...")
	err = os.Chmod(dir+bwFile, 0777)
	if err != nil {
		log.Fatal("Unable to chmod new boxwallet file: ", err)
	}

	fmt.Println(be.CAppName + " has been successfully updated to the latest version: " + sTag)
}

func getLatestVersionTag() (string, error) {
	var ghInfo githubInfo

	resp, err := http.Get("https://api.github.com/repos/richardltc/boxwallet/releases/latest")
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	err = json.Unmarshal(body, &ghInfo)
	if err != nil {
		return "", err
	}
	return ghInfo.TagName, nil
}
