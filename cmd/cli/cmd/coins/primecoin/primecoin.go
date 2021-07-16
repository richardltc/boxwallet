package primecoin

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/ioutil"
	"net/http"
	"os"
	"os/exec"
	"os/user"
	be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/fileutils"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/rjminternet"
	"runtime"
	"strconv"
	"strings"
)

const (
	cCoinName       string = "Primecoin"
	cCoinNameAbbrev string = "XPM"

	cCoreVersion string = "0.1.5"
	//cDownloadFileArm32        = "peercoin-" + cCoreVersion + "-arm-linux-gnueabihf.tar.gz"
	//cDownloadFileArm64        = "peercoin-" + cCoreVersion + "-aarch64-linux-gnu.tar.gz"
	cDownloadFileLin   = "primecoind-" + cCoreVersion + "-linux"
	cDownloadFilemacOS = "peercoin-" + cCoreVersion + "-osx64.tar.gz"
	//CDFFileWindowsPeercoin = "peercoin-" + CCoreVersionPeercoin + "-win64.zip"

	// Directory constants

	cExtractedDirArm string = "peercoin-" + cCoreVersion + "/"
	//cExtractedDirLin string = "peercoin-" + cCoreVersion + "/"
	cExtractedDirWin string = "peercoin-" + cCoreVersion + "\\"
	//https://github.com/primecoin/primecoin/releases/download/v0.1.5xpm/primecoind-0.1.5-linux
	cDownloadURL string = "https://github.com/primecoin/primecoin/releases/download/v" + cCoreVersion + "xpm/"

	// Peercoin Wallet Constants
	cHomeDirLin string = ".primecoin"
	cHomeDirWin string = "primecoin"

	// File constants
	cConfFile      string = "primecoin.conf"
	cCliFileLin    string = "primecoin-cli"
	cCliFileWin    string = "primecoin-cli.exe"
	cDaemonFileLin string = "primecoind-0.1.5-linux"
	cDaemonFileWin string = "primecoind.exe"
	cTxFileLin     string = "primecoin-tx"
	cTxFileWin     string = "primecoin-tx.exe"

	cTipAddress string = "not entered"

	// pivx.conf file constants.
	cRPCUser string = "primecoinrpc"
	cRPCPort string = "8332"
)

type Primecoin struct {
	RPCUser     string
	RPCPassword string
	IPAddress   string
	Port        string
}

func (p Primecoin) Bootstrap(rpcUser, rpcPassword, ip, port string) {
	p.RPCUser = rpcUser
	p.RPCPassword = rpcPassword
	p.IPAddress = ip
	p.Port = port
}

func (p Primecoin) AbbreviatedCoinName() string {
	return cCoinNameAbbrev
}

func (p Primecoin) AllBinaryFilesExist(dir string) (bool, error) {
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

//func (p Primecoin) AnyAddresses(auth *models.CoinAuth) (bool, error) {
//	addresses, err := p.ListReceivedByAddress(auth, false)
//	if err != nil {
//		return false, err
//	}
//	if len(addresses.Result) > 0 {
//		return true, nil
//	}
//	return false, nil
//}

//func (p Primecoin) BlockchainInfo(auth *models.CoinAuth) (models.XPMBlockchainInfo, error) {
//	var respStruct models.XPMBlockchainInfo
//
//	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getblockchaininfo\",\"params\":[]}")
//	req, err := http.NewRequest("POST", "http://"+auth.IPAddress+":"+auth.Port, body)
//	if err != nil {
//		return respStruct, err
//	}
//	req.SetBasicAuth(auth.RPCUser, auth.RPCPassword)
//	req.Header.Set("Content-Type", "text/plain;")
//
//	resp, err := http.DefaultClient.Do(req)
//	if err != nil {
//		return respStruct, err
//	}
//	defer resp.Body.Close()
//	bodyResp, err := ioutil.ReadAll(resp.Body)
//	if err != nil {
//		return respStruct, err
//	}
//	err = json.Unmarshal(bodyResp, &respStruct)
//	if err != nil {
//		return respStruct, err
//	}
//	return respStruct, nil
//}

//func (p Primecoin) BlockchainIsSynced(coinAuth *models.CoinAuth) (bool, error) {
//	bci, err := p.BlockchainInfo(coinAuth)
//	if err != nil {
//		return false, err
//	}
//
//	if bci.Result.Verificationprogress > 0.99999 {
//		return true, nil
//	}
//
//	return false, nil
//}

func (p Primecoin) ConfFile() string {
	return cConfFile
}

func (p Primecoin) CoinName() string {
	return cCoinName
}

func (p Primecoin) CoinNameAbbrev() string {
	return cCoinNameAbbrev
}

func (p Primecoin) DaemonFilename() string {
	if runtime.GOOS == "windows" {
		return cDaemonFileWin
	}

	return cDaemonFileLin
}

func (p Primecoin) DaemonRunning() (bool, error) {
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

// DownloadCoin - Downloads the Syscoin files into the spcified location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (p Primecoin) DownloadCoin(location string) error {
	var fullFilePath, fullFileDLURL string

	switch runtime.GOOS {
	case "windows":
		return errors.New("Windows is not currently supported for :" + cCoinName)
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			return errors.New("ARM32 is not currently supported for :" + cCoinName)
		case "arm64":
			return errors.New("ARM64 is not currently supported for :" + cCoinName)
		case "386":
			return errors.New("linux 386 is not currently supported for :" + cCoinName)
		case "amd64":
			fullFilePath = location + cDownloadFileLin
			fullFileDLURL = cDownloadURL + cDownloadFileLin
		}
	}

	if err := rjminternet.DownloadFile(fullFilePath, fullFileDLURL); err != nil {
		return fmt.Errorf("unable to download file: %v - %v", fullFileDLURL, err)
	}

	return nil
}

func (p Primecoin) HomeDir() string {
	if runtime.GOOS == "windows" {
		return cHomeDirWin
	} else {
		return cHomeDirLin
	}
}

func (p Primecoin) HomeDirFullPath() (string, error) {
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
func (p Primecoin) Install(location string) error {

	// Copy files to correct location
	var srcPath, sfD string

	switch runtime.GOOS {
	case "windows":
		return errors.New("windows is not currently supported for " + cCoinName)
	case "linux":
		switch runtime.GOARCH {
		case "arm", "arm64":
			return errors.New("arm is not currently supported for " + cCoinName)
		case "amd64":
			srcPath = location
			sfD = cDaemonFileLin
		default:
			return errors.New("unable to determine runtime.GOARCH " + runtime.GOARCH)
		}
	default:
		return errors.New("unable to determine runtime.GOOS")
	}

	// If the coind file doesn't already exists the copy it.
	if _, err := os.Stat(location + sfD); os.IsNotExist(err) {
		if err := fileutils.FileCopy(srcPath+sfD, location+sfD, false); err != nil {
			return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+sfD, location+sfD, err)
		}
	}
	if err := os.Chmod(location+sfD, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", location+sfD, err)
	}

	return nil
}

//func (p Peercoin) ListReceivedByAddress(coinAuth *models.CoinAuth, includeZero bool) (models.PPCListReceivedByAddress, error) {
//	var respStruct models.PPCListReceivedByAddress
//
//	var s string
//	if includeZero {
//		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, true]}"
//	} else {
//		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, false]}"
//	}
//	body := strings.NewReader(s)
//	req, err := http.NewRequest("POST", "http://"+coinAuth.IPAddress+":"+coinAuth.Port, body)
//	if err != nil {
//		return respStruct, err
//	}
//	req.SetBasicAuth(coinAuth.RPCUser, coinAuth.RPCPassword)
//	req.Header.Set("Content-Type", "text/plain;")
//
//	resp, err := http.DefaultClient.Do(req)
//	if err != nil {
//		return respStruct, err
//	}
//	defer resp.Body.Close()
//	bodyResp, err := ioutil.ReadAll(resp.Body)
//	if err != nil {
//		return respStruct, err
//	}
//
//	err = json.Unmarshal(bodyResp, &respStruct)
//	if err != nil {
//		return respStruct, err
//	}
//
//	return respStruct, nil
//}
//
//func (p Peercoin) ListTransactions(auth *models.CoinAuth) (models.PPCListTransactions, error) {
//	var respStruct models.PPCListTransactions
//
//	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandListTransactions + "\",\"params\":[]}")
//	req, err := http.NewRequest("POST", "http://"+auth.IPAddress+":"+auth.Port, body)
//	if err != nil {
//		return respStruct, err
//	}
//	req.SetBasicAuth(auth.RPCUser, auth.RPCPassword)
//	req.Header.Set("Content-Type", "text/plain;")
//
//	resp, err := http.DefaultClient.Do(req)
//	if err != nil {
//		return respStruct, err
//	}
//	defer resp.Body.Close()
//	bodyResp, err := ioutil.ReadAll(resp.Body)
//	if err != nil {
//		return respStruct, err
//	}
//
//	err = json.Unmarshal(bodyResp, &respStruct)
//	if err != nil {
//		return respStruct, err
//	}
//
//	return respStruct, nil
//}

func (p Primecoin) NetworkDifficultyInfo() (float64, float64, error) {
	// https://chainz.cryptoid.info/ftc/api.dws?q=getdifficulty

	resp, err := http.Get("https://chainz.cryptoid.info/" + strings.ToLower(p.CoinNameAbbrev()) + "/api.dws?q=getdifficulty")
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

//func (p Peercoin) NetworkInfo(coinAuth *models.CoinAuth) (models.PPCNetworkInfo, error) {
//	var respStruct models.PPCNetworkInfo
//
//	for i := 1; i < 50; i++ {
//		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandGetNetworkInfo + "\",\"params\":[]}")
//
//		req, err := http.NewRequest("POST", "http://"+coinAuth.IPAddress+":"+coinAuth.Port, body)
//		if err != nil {
//			return respStruct, err
//		}
//		req.SetBasicAuth(coinAuth.RPCUser, coinAuth.RPCPassword)
//		req.Header.Set("Content-Type", "text/plain;")
//
//		resp, err := http.DefaultClient.Do(req)
//		if err != nil {
//			return respStruct, err
//		}
//		defer resp.Body.Close()
//		bodyResp, err := ioutil.ReadAll(resp.Body)
//		if err != nil {
//			return respStruct, err
//		}
//
//		// Check to make sure we are not loading the wallet
//		if bytes.Contains(bodyResp, []byte("Loading")) ||
//			bytes.Contains(bodyResp, []byte("Rescanning")) ||
//			bytes.Contains(bodyResp, []byte("Rewinding")) ||
//			bytes.Contains(bodyResp, []byte("Verifying")) {
//			// The wallet is still loading, so print message, and sleep for 3 seconds and try again
//			time.Sleep(5 * time.Second)
//		} else {
//			_ = json.Unmarshal(bodyResp, &respStruct)
//			return respStruct, err
//		}
//	}
//	return respStruct, nil
//}
//
//func (p Peercoin) NewAddress(auth *models.CoinAuth) (models.PPCNewAddress, error) {
//	var respStruct models.PPCNewAddress
//
//	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getnewaddress\",\"params\":[]}")
//	req, err := http.NewRequest("POST", "http://"+auth.IPAddress+":"+auth.Port, body)
//	if err != nil {
//		return respStruct, err
//	}
//	req.SetBasicAuth(auth.RPCUser, auth.RPCPassword)
//	req.Header.Set("Content-Type", "text/plain;")
//
//	resp, err := http.DefaultClient.Do(req)
//	if err != nil {
//		return respStruct, err
//	}
//	defer resp.Body.Close()
//	bodyResp, err := ioutil.ReadAll(resp.Body)
//	if err != nil {
//		return respStruct, err
//	}
//
//	err = json.Unmarshal(bodyResp, &respStruct)
//	if err != nil {
//		return respStruct, err
//	}
//
//	return respStruct, nil
//}

func (p Primecoin) RPCDefaultUsername() string {
	return cRPCUser
}

func (p Primecoin) RPCDefaultPort() string {
	return cRPCPort
}

func (p Primecoin) StartDaemon(displayOutput bool, appFolder string, auth *models.CoinAuth) error {
	if runtime.GOOS == "windows" {
		//_ = exec.Command(GetAppsBinFolder() + cDiviDFileWin)
		fp := appFolder + cDaemonFileWin
		cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
		if err := cmd.Run(); err != nil {
			return err
		}
	} else {
		if displayOutput {
			fmt.Println("Attempting to run the " + cDaemonFileLin + " daemon...")
		}

		cmdRun := exec.Command(appFolder + cDaemonFileLin)
		if err := cmdRun.Start(); err != nil {
			return err
		}
		if displayOutput {
			fmt.Println(cCoinName + " server starting")
		}

		//	stdout, err := cmdRun.StdoutPipe()
		//	if err != nil {
		//		return err
		//	}
		//	err = cmdRun.Start()
		//	if err != nil {
		//		return err
		//	}
		//
		//	buf := bufio.NewReader(stdout)
		//	num := 1
		//	for {
		//		line, _, _ := buf.ReadLine()
		//		if num > 3 {
		//			os.Exit(0)
		//		}
		//		num++
		//		if string(line) == "Peercoin server starting" {
		//			if displayOutput {
		//				fmt.Println("Peercoin server starting")
		//			}
		//			return nil
		//		} else {
		//			return errors.New("unable to start Peercoin server: " + string(line))
		//		}
		//	}
	}
	return nil
}

func (p Primecoin) StopDaemon(auth *models.CoinAuth) error {
	var respStruct models.GenericResponse

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
	bodyResp, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	err = json.Unmarshal(bodyResp, &respStruct)
	if err != nil {
		return err
	}
	return nil
}

func (p Primecoin) TipAddress() string {
	return cTipAddress
}

func (p Primecoin) WalletEncrypt(coinAuth *models.CoinAuth, pw string) (be.GenericRespStruct, error) {
	var respStruct be.GenericRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandEncryptWallet + "\",\"params\":[\"" + pw + "\"]}")
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

//func (p Peercoin) WalletInfo(coinAuth *models.CoinAuth) (models.PPCWalletInfo, error) {
//	var respStruct models.PPCWalletInfo
//
//	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandGetWalletInfo + "\",\"params\":[]}")
//	req, err := http.NewRequest("POST", "http://"+coinAuth.IPAddress+":"+coinAuth.Port, body)
//	if err != nil {
//		return respStruct, err
//	}
//	req.SetBasicAuth(coinAuth.RPCUser, coinAuth.RPCPassword)
//	req.Header.Set("Content-Type", "text/plain;")
//
//	resp, err := http.DefaultClient.Do(req)
//	if err != nil {
//		return respStruct, err
//	}
//	defer resp.Body.Close()
//	bodyResp, err := ioutil.ReadAll(resp.Body)
//	if err != nil {
//		return respStruct, err
//	}
//
//	err = json.Unmarshal(bodyResp, &respStruct)
//	if err != nil {
//		return respStruct, err
//	}
//
//	// Check to see if the json response contains "unlocked_until"
//	s := string(bodyResp)
//	if !strings.Contains(s, "unlocked_until") {
//		respStruct.Result.UnlockedUntil = -1
//	}
//
//	return respStruct, nil
//}

func (p Primecoin) WalletLoadingStatus(auth *models.CoinAuth) models.WLSType {
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

//func (p Peercoin) WalletNeedsEncrypting(coinAuth *models.CoinAuth) (bool, error) {
//	wi, err := p.WalletInfo(coinAuth)
//	if err != nil {
//		return true, errors.New("Unable to perform WalletInfo " + err.Error())
//	}
//
//	if wi.Result.UnlockedUntil < 0 {
//		return true, nil
//	}
//
//	return false, nil
//}

func (p Primecoin) WalletResync(appFolder string) error {
	daemonRunning, err := p.DaemonRunning()
	if err != nil {
		return errors.New("Unable to determine DaemonRunning: " + err.Error())
	}
	if daemonRunning {
		return errors.New("daemon is still running, please stop first")
	}

	arg1 := "-resync"

	if runtime.GOOS == "windows" {
		fullPath := appFolder + cDaemonFileWin
		cmd := exec.Command("cmd.exe", "/C", "start", "/b", fullPath, arg1)
		if err := cmd.Run(); err != nil {
			return err
		}
	} else {
		fullPath := appFolder + cDaemonFileLin
		cmdRun := exec.Command(fullPath, arg1)
		if err := cmdRun.Run(); err != nil {
			return err
		}
	}

	return nil
}

//func (p Peercoin) WalletSecurityState(coinAuth *models.CoinAuth) (models.WEType, error) {
//	wi, err := p.WalletInfo(coinAuth)
//	if err != nil {
//		return models.WETUnknown, errors.New("Unable to GetWalletSecurityState: " + err.Error())
//	}
//
//	if wi.Result.UnlockedUntil == 0 {
//		return models.WETLocked, nil
//	} else if wi.Result.UnlockedUntil == -1 {
//		return models.WETUnencrypted, nil
//	} else if wi.Result.UnlockedUntil > 0 {
//		return models.WETUnlockedForStaking, nil
//	} else {
//		return models.WETUnknown, nil
//	}
//}

//func (p Peercoin) WalletUnlockFS(coinAuth *models.CoinAuth, pw string) error {
//	var respStruct be.GenericRespStruct
//	var body *strings.Reader
//
//	body = strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",9999999,true]}")
//
//	req, err := http.NewRequest("POST", "http://"+coinAuth.IPAddress+":"+coinAuth.Port, body)
//	if err != nil {
//		return err
//	}
//	req.SetBasicAuth(coinAuth.RPCUser, coinAuth.RPCPassword)
//	req.Header.Set("Content-Type", "text/plain;")
//
//	resp, err := http.DefaultClient.Do(req)
//	if err != nil {
//		return err
//	}
//	defer resp.Body.Close()
//	bodyResp, err := ioutil.ReadAll(resp.Body)
//	if err != nil {
//		return err
//	}
//	err = json.Unmarshal(bodyResp, &respStruct)
//	if err != nil || respStruct.Error != nil {
//		return err
//	}
//	return nil
//}

func (p Primecoin) WalletUnlock(coinAuth *models.CoinAuth, pw string) error {
	var respStruct models.GenericResponse

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",0]}")
	req, err := http.NewRequest("POST", "http://"+coinAuth.IPAddress+":"+coinAuth.Port, body)
	if err != nil {
		return err
	}
	req.SetBasicAuth(coinAuth.RPCUser, coinAuth.RPCPassword)
	req.Header.Set("Content-Type", "text/plain;")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	bodyResp, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	err = json.Unmarshal(bodyResp, &respStruct)
	if err != nil {
		return err
	}
	return nil
}

func (p Primecoin) UpdateTickerInfo() (ticker models.PPCTicker, err error) {
	resp, err := http.Get("https://ticker.neist.io/" + cCoinNameAbbrev)
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
