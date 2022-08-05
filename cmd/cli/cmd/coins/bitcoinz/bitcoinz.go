package bitcoinz

import (
	"bufio"
	"bytes"
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
	"strconv"
	"strings"
	"time"

	"github.com/go-cmd/cmd"
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

	cFetchParams string = "fetch-params.sh"
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

func (b Bitcoinz) BlockchainInfo(coinAuth *models.CoinAuth) (models.BTCZBlockchainInfo, error) {
	var respStruct models.BTCZBlockchainInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandGetBCInfo + "\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+coinAuth.IPAddress+":"+coinAuth.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(coinAuth.RPCUser, coinAuth.RPCPassword)
	req.Header.Set("Content-Type", "text/plain;")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return respStruct, err
	}
	defer resp.Body.Close()
	bodyResp, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return respStruct, err
	}
	err = json.Unmarshal(bodyResp, &respStruct)
	if err != nil {
		return respStruct, err
	}

	return respStruct, nil
}

func (b Bitcoinz) BlockchainIsSynced(coinAuth *models.CoinAuth) (bool, error) {
	bci, err := b.BlockchainInfo(coinAuth)
	if err != nil {
		return false, err
	}

	if bci.Result.Verificationprogress > 0.99999 {
		return true, nil
	}

	return false, nil
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

	// If the fetch-params.sh file doesn't exist the copy it.
	if _, err := os.Stat(location + cFetchParams); os.IsNotExist(err) {
		if err := fileutils.FileCopy(srcPath+cFetchParams, location+cFetchParams, false); err != nil {
			return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+cFetchParams, location+cFetchParams, err)
		}
	}
	if err := os.Chmod(location+cFetchParams, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", location+cFetchParams, err)
	}

	// run the fetch-params.sh script
	if runtime.GOOS == "windows" {
		fp := location + cFetchParams
		cmd := exec.Command("cmd.exe", "/C", "/b", fp)
		if err := cmd.Run(); err != nil {
			return err
		}
	} else {
		fp := location + cFetchParams
		if err := smartRun(fp); err != nil {
			return err
		}

		//cmd := exec.Command(fp)
		//stdout, err := cmd.StdoutPipe()
		//if err != nil {
		//	return err
		//}
		//cmd.Start()
		//
		//buf := bufio.NewReader(stdout) // Notice that this is not in a loop
		//num := 1
		//for {
		//	line, _, _ := buf.ReadLine()
		//	if num > 100 {
		//		os.Exit(0)
		//	}
		//	num += 1
		//	fmt.Println(string(line))
		//}
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

func (b Bitcoinz) ListTransactions(auth *models.CoinAuth) (models.BTCZListTransactions, error) {
	var respStruct models.BTCZListTransactions

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandListTransactions + "\",\"params\":[\"*\",25,0]}")
	req, err := http.NewRequest("POST", "http://"+auth.IPAddress+":"+auth.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(auth.RPCUser, auth.RPCPassword)
	req.Header.Set("Content-Type", "text/plain;")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return respStruct, err
	}
	defer resp.Body.Close()
	bodyResp, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return respStruct, err
	}

	err = json.Unmarshal(bodyResp, &respStruct)
	if err != nil {
		return respStruct, err
	}

	return respStruct, nil
}

func (b Bitcoinz) NetworkDifficultyInfo() (float64, float64, error) {
	// https://chainz.cryptoid.info/ftc/api.dws?q=getdifficulty

	resp, err := http.Get("https://chainz.cryptoid.info/" + strings.ToLower(b.CoinNameAbbrev()) + "/api.dws?q=getdifficulty")
	if err != nil {
		return 0, 0, err
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return 0, 0, err
	}

	var fGood float64
	var fWarning float64

	// Now calculate the correct levels...
	if fDiff, err := strconv.ParseFloat(string(body), 32); err == nil {
		fGood = fDiff * 0.75
		fWarning = fDiff * 0.50
	}

	return fGood, fWarning, nil
}

func (b Bitcoinz) NetworkInfo(coinAuth *models.CoinAuth) (models.BTCZNetworkInfo, error) {
	var respStruct models.BTCZNetworkInfo

	for i := 1; i < 50; i++ {
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandGetNetworkInfo + "\",\"params\":[]}")

		req, err := http.NewRequest("POST", "http://"+coinAuth.IPAddress+":"+coinAuth.Port, body)
		if err != nil {
			return respStruct, err
		}
		req.SetBasicAuth(coinAuth.RPCUser, coinAuth.RPCPassword)
		req.Header.Set("Content-Type", "text/plain;")

		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return respStruct, err
		}
		defer resp.Body.Close()
		bodyResp, err := ioutil.ReadAll(resp.Body)
		if err != nil {
			return respStruct, err
		}

		// Check to make sure we are not loading the wallet
		if bytes.Contains(bodyResp, []byte("Loading")) ||
			bytes.Contains(bodyResp, []byte("Rescanning")) ||
			bytes.Contains(bodyResp, []byte("Rewinding")) ||
			bytes.Contains(bodyResp, []byte("Verifying")) {
			// The wallet is still loading, so print message, and sleep for 3 seconds and try again
			time.Sleep(5 * time.Second)
		} else {
			_ = json.Unmarshal(bodyResp, &respStruct)
			return respStruct, err
		}
	}

	return respStruct, nil
}

func (b Bitcoinz) RPCDefaultUsername() string {
	return cRPCUser
}

func (b Bitcoinz) RPCDefaultPort() string {
	return cRPCPort
}

func smartRun(cmdStr string) error {
	// Start a long-running process, capture stdout and stderr
	runCmd := cmd.NewCmd(cmdStr)
	statusChan := runCmd.Start() // non-blocking

	ticker := time.NewTicker(2 * time.Second)

	// Print last line of stdout every 2s
	go func() {
		for range ticker.C {
			status := runCmd.Status()
			n := len(status.Stdout)
			fmt.Println(status.Stdout[n-1])
		}
	}()

	// Stop command after 1 hour
	go func() {
		<-time.After(1 * time.Hour)
		runCmd.Stop()
	}()

	// Check if command is done
	select {
	case finalStatus := <-statusChan:
		return finalStatus.Error
	default:
		// no, still running
	}

	// Block waiting for command to exit, be stopped, or be killed
	finalStatus := <-statusChan

	return finalStatus.Error
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

func (b Bitcoinz) UpdateTickerInfo() (ticker models.BTCZTicker, err error) {
	resp, err := http.Get("https://ticker.neist.io/BTCZ")
	if err != nil {
		return ticker, err
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return ticker, err
	}
	err = json.Unmarshal(body, &ticker)
	if err != nil {
		return ticker, err
	}

	return ticker, nil
}

func (b *Bitcoinz) WalletInfo(coinAuth *models.CoinAuth) (models.BTCZWalletInfo, error) {
	var respStruct models.BTCZWalletInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandGetWalletInfo + "\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+coinAuth.IPAddress+":"+coinAuth.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(coinAuth.RPCUser, coinAuth.RPCPassword)
	req.Header.Set("Content-Type", "text/plain;")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return respStruct, err
	}
	defer resp.Body.Close()
	bodyResp, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return respStruct, err
	}

	err = json.Unmarshal(bodyResp, &respStruct)
	if err != nil {
		return respStruct, err
	}

	// Check to see if the json response contains "unlocked_until"
	s := string(bodyResp)
	if !strings.Contains(s, "unlocked_until") {
		respStruct.Result.UnlockedUntil = -1
	}

	return respStruct, nil
}

func (b Bitcoinz) WalletLoadingStatus(auth *models.CoinAuth) models.WLSType {
	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandGetInfo + "\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+auth.IPAddress+":"+auth.Port, body)
	if err != nil {
		return models.WLSTUnknown
	}
	req.SetBasicAuth(auth.RPCUser, auth.RPCPassword)
	req.Header.Set("Content-Type", "text/plain;")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return models.WLSTWaitingForResponse
	} else {
		defer resp.Body.Close()
		bodyResp, err := ioutil.ReadAll(resp.Body)
		if err != nil {
			return models.WLSTWaitingForResponse
		}

		if bytes.Contains(bodyResp, []byte("Loading")) {
			return models.WLSTLoading
		}
		if bytes.Contains(bodyResp, []byte("Rescanning")) {
			return models.WLSTRescanning
		}
		if bytes.Contains(bodyResp, []byte("Rewinding")) {
			return models.WLSTRewinding
		}
		if bytes.Contains(bodyResp, []byte("Verifying")) {
			return models.WLSTVerifying
		}
		if bytes.Contains(bodyResp, []byte("Calculating money supply")) {
			return models.WLSTCalculatingMoneySupply
		}
	}
	return models.WLSTReady
}

func (b Bitcoinz) WalletNeedsEncrypting(coinAuth *models.CoinAuth) (bool, error) {
	wi, err := b.WalletInfo(coinAuth)
	if err != nil {
		return true, errors.New("Unable to perform WalletInfo " + err.Error())
	}

	if wi.Result.UnlockedUntil == -1 {
		return true, nil
	}

	return false, nil
}

func (b Bitcoinz) WalletResync(appFolder string) error {
	daemonRunning, err := b.DaemonRunning()
	if err != nil {
		return errors.New("Unable to determine DaemonRunning: " + err.Error())
	}
	if daemonRunning {
		return errors.New("daemon is still running, please stop first")
	}

	arg1 := "-resync"

	cRun := exec.Command(appFolder+cDaemonFileLin, arg1)
	if err := cRun.Run(); err != nil {
		return fmt.Errorf("unable to run "+cDaemonFileLin+" "+arg1+": %v", err)
	}

	return nil
}

func (b Bitcoinz) WalletSecurityState(coinAuth *models.CoinAuth) (models.WEType, error) {
	wi, err := b.WalletInfo(coinAuth)
	if err != nil {
		return models.WETUnknown, errors.New("Unable to determine WalletSecurityState: " + err.Error())
	}

	if wi.Result.UnlockedUntil == 0 {
		return models.WETLocked, nil
	} else if wi.Result.UnlockedUntil == -1 {
		return models.WETUnencrypted, nil
	} else if wi.Result.UnlockedUntil > 0 {
		return models.WETUnlockedForStaking, nil
	} else {
		return models.WETUnknown, nil
	}
}
