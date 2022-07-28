package bend

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io/ioutil"
	"net/http"
	"os"
	"os/exec"
	"os/user"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/fileutils"
	"runtime"
	"strings"

	"github.com/mholt/archiver"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/rjminternet"
)

const (
	cCoinName       string = "BitcoinZ"
	cCoinNameAbbrev string = "BTCZ"

	cAPIURL string = "https://api.github.com/repos/btcz/bitcoinz/releases/latest"

	cHomeDirLin string = ".bitcoinz"
	cHomeDirWin string = "BITCOINZ"

	cConfFile      string = "bitcoinz.conf"
	cCliFileLin    string = "bitcoinz-cli"
	cCliFileWin    string = "bitcoinz-cli.exe"
	cDaemonFileLin string = "bitcoinzd"
	cDaemonFileWin string = "bitcoinzd.exe"
	cTxFileLin     string = "bitcoinz-tx"
	cTxFileWin     string = "bitcoinz-tx.exe"

	cTipAddress string = "t1RQxnbaAQW88evTHtFGvfSywyE9tNA24ym"

	// bitcoinz.conf file constants
	cRPCUser string = "bitcoinzrpc"
	cRPCPort string = "1979"
)

type Bitcoinz struct {
	RPCUser     string
	RPCPassword string
	IPAddress   string
	Port        string
}

func (b Bitcoinz) Bootstrap(rpcUser, rpcPassword, ip, port string) {
	b.RPCUser = rpcUser
	b.RPCPassword = rpcPassword
	b.IPAddress = ip
	b.Port = port
}

func (b Bitcoinz) AbbreviatedCoinName() string {
	return cCoinNameAbbrev
}

func (b Bitcoinz) AllBinaryFilesExist(dir string) (bool, error) {
	if runtime.GOOS == "windows" {
		if !fileutils.FileExists(dir + cCliFileWin) {
			return false, nil
		}
		if !fileutils.FileExists(dir + cDaemonFileWin) {
			return false, nil
		}
		if !fileutils.FileExists(dir + cTxFileWin) {
			return false, nil
		}
	} else {
		if !fileutils.FileExists(dir + cCliFileLin) {
			return false, nil
		}
		if !fileutils.FileExists(dir + cDaemonFileLin) {
			return false, nil
		}
		if !fileutils.FileExists(dir + cTxFileLin) {
			return false, nil
		}
	}

	return true, nil
}

func archStrToFile(arch string, ghInfo *models.GithubInfo) (fileName string) {
	for _, a := range ghInfo.Assets {
		if strings.Contains(a.Name, arch) {
			return a.Name
		}
	}

	return ""
}

func archStrToFileDownloadURL(arch string, ghInfo *models.GithubInfo) string {
	for _, a := range ghInfo.Assets {
		if strings.Contains(a.BrowserDownloadURL, arch) {
			return a.BrowserDownloadURL
		}
	}

	return ""
}

func (b Bitcoinz) ConfFile() string {
	return cConfFile
}

func (b Bitcoinz) CoinName() string {
	return cCoinName
}

func (b Bitcoinz) CoinNameAbbrev() string {
	return cCoinNameAbbrev
}

func (b Bitcoinz) DaemonRunning() (bool, error) {
	var err error

	if runtime.GOOS == "windows" {
		_, _, err = coins.FindProcess(cDaemonFileWin)
	} else {
		_, _, err = coins.FindProcess(cDaemonFileLin)
	}

	if err == nil {
		return true, nil
	}
	if err.Error() == "not found" {
		return false, nil
	} else {
		return false, err
	}
}

// DownloadCoin - Downloads the BitcoinZ files into the specified location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (b Bitcoinz) DownloadCoin(location string) error {
	var fullFilePath string

	ghInfo, err := latestAssets()
	if err != nil {
		return err
	}

	downloadFile, err := latestDownloadFile(&ghInfo)
	if err != nil {
		return err
	}

	fullFileDLURL, err := latestDownloadFileURL(&ghInfo)
	if err != nil {
		return err
	}

	fullFilePath = location + downloadFile

	if err := rjminternet.DownloadFile(fullFilePath, fullFileDLURL); err != nil {
		return fmt.Errorf("unable to download file: %v - %v", fullFilePath+fullFileDLURL, err)
	}

	// Unarchive the files
	if err := b.unarchiveFile(fullFilePath, location, downloadFile); err != nil {
		return err
	}

	return nil
}

func (b Bitcoinz) DaemonFilename() string {
	if runtime.GOOS == "windows" {
		return cDaemonFileWin
	} else {
		return cDaemonFileLin
	}
}

func (b Bitcoinz) extractedDir() (string, error) {
	ghInfo, err := latestAssets()
	if err != nil {
		return "", err
	}

	var s string
	switch runtime.GOOS {
	case "windows":
		tn := strings.ReplaceAll(ghInfo.TagName, "v", "")
		s = strings.ToLower(cCoinName) + "-" + tn + "\\"
	case "linux":
		tn := strings.ReplaceAll(ghInfo.TagName, "v", "")
		s = strings.ToLower(cCoinName) + "-" + tn + "/"
	default:
		return "", errors.New("unable to determine runtime.GOOS")
	}

	return s, nil
}

func (b Bitcoinz) HomeDir() string {
	if runtime.GOOS == "windows" {
		return cHomeDirWin
	} else {
		return cHomeDirLin
	}
}

func (b Bitcoinz) HomeDirFullPath() (string, error) {
	u, err := user.Current()
	if err != nil {
		return "", err
	}
	hd := u.HomeDir

	if runtime.GOOS == "windows" {
		return fileutils.AddTrailingSlash(hd) + "appdata\\roaming\\" + fileutils.AddTrailingSlash(cHomeDirWin), nil
	} else {
		return fileutils.AddTrailingSlash(hd) + fileutils.AddTrailingSlash(cHomeDirLin), nil
	}
}

// Install - Puts the freshly downloaded files into their correct location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (b Bitcoinz) Install(location string) error {

	// Copy files to correct location
	var srcPath, srcFileCLI, srcFileDaemon, srcFileTX string

	switch runtime.GOOS {
	case "windows":
		srcPath = location
		srcFileCLI = cCliFileWin
		srcFileDaemon = cDaemonFileWin
		srcFileTX = cTxFileWin
	case "linux":
		switch runtime.GOARCH {
		case "arm", "arm64":
			srcPath = location
			srcFileCLI = cCliFileLin
			srcFileDaemon = cDaemonFileLin
			srcFileTX = cTxFileLin
		case "amd64":
			srcPath = location
			srcFileCLI = cCliFileLin
			srcFileDaemon = cDaemonFileLin
			srcFileTX = cTxFileLin
		default:
			return errors.New("unable to determine runtime.GOARCH " + runtime.GOARCH)
		}
	default:
		return errors.New("unable to determine runtime.GOOS")
	}

	// If the coin-cli file doesn't exist the copy it.
	if _, err := os.Stat(location + srcFileCLI); os.IsNotExist(err) {
		if err := fileutils.FileCopy(srcPath+srcFileCLI, location+srcFileCLI, false); err != nil {
			return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+srcFileCLI, location+srcFileCLI, err)
		}
	}
	if err := os.Chmod(location+srcFileCLI, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", location+srcFileCLI, err)
	}

	// If the coind file doesn't exist the copy it.
	if _, err := os.Stat(location + srcFileDaemon); os.IsNotExist(err) {
		if err := fileutils.FileCopy(srcPath+srcFileDaemon, location+srcFileDaemon, false); err != nil {
			return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+srcFileDaemon, location+srcFileDaemon, err)
		}
	}
	if err := os.Chmod(location+srcFileDaemon, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", location+srcFileDaemon, err)
	}

	// If the cointx file doesn't exist the copy it.
	if _, err := os.Stat(location + srcFileTX); os.IsNotExist(err) {
		if err := fileutils.FileCopy(srcPath+srcFileTX, location+srcFileTX, false); err != nil {
			return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+srcFileTX, location+srcFileTX, err)
		}
	}
	if err := os.Chmod(location+srcFileTX, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", location+srcFileTX, err)
	}

	return nil
}

func latestAssets() (models.GithubInfo, error) {
	var ghInfo models.GithubInfo

	resp, err := http.Get(cAPIURL)
	if err != nil {
		return ghInfo, err
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return ghInfo, err
	}
	err = json.Unmarshal(body, &ghInfo)
	if err != nil {
		return ghInfo, err
	}

	return ghInfo, nil
}

func latestDownloadFile(ghInfo *models.GithubInfo) (string, error) {
	var sFile string
	switch runtime.GOOS {
	case "windows":
		sFile = archStrToFile("win64", ghInfo)
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			return "", errors.New("arm is not currently supported for :" + cCoinName)
		case "arm64":
			sFile = archStrToFile("aarch64", ghInfo)
		case "386":
			return "", errors.New("linux 386 is not currently supported for :" + cCoinName)
		case "amd64":
			sFile = archStrToFile("ubuntu2004-linux64.zip", ghInfo)
		}
	}

	if sFile == "" {
		return "", errors.New("unable to determine download url - latestDownloadFileURL")
	}

	return sFile, nil
}

func latestDownloadFileURL(ghInfo *models.GithubInfo) (string, error) {
	var sURL string
	switch runtime.GOOS {
	case "windows":
		sURL = archStrToFileDownloadURL("win64", ghInfo)
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			sURL = archStrToFileDownloadURL("arm", ghInfo)
		case "arm64":
			sURL = archStrToFileDownloadURL("aarch64", ghInfo)
		case "386":
			return "", errors.New("linux 386 is not currently supported for :" + cCoinName)
		case "amd64":
			sURL = archStrToFileDownloadURL("ubuntu2004-linux64.zip", ghInfo)
		}
	}

	if sURL == "" {
		return "", errors.New("unable to determine download url - latestDownloadFileURL")
	}

	return sURL, nil
}

func (b Bitcoinz) RPCDefaultUsername() string {
	return cRPCUser
}

func (b Bitcoinz) RPCDefaultPort() string {
	return cRPCPort
}

func (b Bitcoinz) StartDaemon(displayOutput bool, appFolder string) error {
	bDR, _ := b.DaemonRunning()
	if bDR {
		return nil
	}

	if runtime.GOOS == "windows" {
		fp := appFolder + cDaemonFileWin
		cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
		if err := cmd.Run(); err != nil {
			return err
		}
	} else {
		if displayOutput {
			fmt.Println("Attempting to run the " + cCoinName + " daemon...")
		}

		cmdRun := exec.Command(appFolder + cDaemonFileLin)
		stdout, err := cmdRun.StdoutPipe()
		if err != nil {
			return err
		}
		err = cmdRun.Start()
		if err != nil {
			return err
		}

		buf := bufio.NewReader(stdout)
		num := 1
		for {
			line, _, _ := buf.ReadLine()
			if num > 3 {
				os.Exit(0)
			}
			num++
			if string(line) == cCoinName+" server starting" {
				if displayOutput {
					fmt.Println(cCoinName + " server starting")
				}
				return nil
			} else {
				return errors.New("unable to start " + cCoinName + " server: " + string(line))
			}
		}
	}

	return nil
}

func (b Bitcoinz) StopDaemon(auth *models.CoinAuth) error {
	//var respStruct models.GenericResponse

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"stop\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+auth.IPAddress+":"+auth.Port, body)
	if err != nil {
		return err
	}
	req.SetBasicAuth(auth.RPCUser, auth.RPCPassword)
	req.Header.Set("Content-Type", "text/plain;")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	return nil
}

func (b Bitcoinz) TipAddress() string {
	return cTipAddress
}

func (b *Bitcoinz) unarchiveFile(fullFilePath, location, downloadFile string) error {
	if err := archiver.Unarchive(fullFilePath, location); err != nil {
		return fmt.Errorf("unable to unarchive file: %v - %v", fullFilePath, err)
	}

	defer os.RemoveAll(location + downloadFile)

	defer os.Remove(fullFilePath)

	return nil
}
