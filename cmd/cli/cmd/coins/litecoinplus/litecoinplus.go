package litecoinplus

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
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/mholt/archiver/v3"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/rjminternet"
)

const (
	cCoinName       string = "LitecoinPlus"
	cCoinNameAbbrev string = "LCP"

	cHomeDir    string = ".LitecoinPlus"
	cHomeDirWin string = "litecoinplus"

	cCoreVersion         string = "5.1.2.1"
	cDownloadFileLinux          = "linux-packed.zip"
	cDownloadFileWindows        = "litecoinplus-qt.zip"
	//cDownloadFileBS      string = "DIVI-snapshot.zip"

	cExtractedDirLinux   = "linux-packed/"
	cExtractedDirWindows = "divi-" + cCoreVersion + "\\"

	cDownloadURL = "https://litecoinplus.co/downloads/"
	//cDownloadURLBS string = "https://snapshots.diviproject.org/dist/"

	cConfFile string = "litecoinplus.conf"
	//cCliFile       string = "divi-cli"
	//cCliFileWin    string = "divi-cli.exe"
	cDaemonFileLin string = "litecoinplusd"
	cDaemonFileWin string = "litecoinplusd.exe"
	//cTxFile        string = "divi-tx"
	//cTxFileWin     string = "divi-tx.exe"

	// divi.conf file constants.
	cRPCUser string = "litecoinplusrpc"
	cRPCPort string = "44350"

	cTipAddress string = "XSkTNFjTUA2fhexZH271GiPzkhJGknV38K"

	// Wallet encryption status
	CWalletESUnlockedForStaking = "unlocked-for-staking"
	CWalletESLocked             = "locked"
	CWalletESUnlocked           = "unlocked"
	CWalletESUnencrypted        = "unencrypted"

	// General CLI command constants
	cCommandGetBCInfo             string = "getblockchaininfo"
	cCommandGetInfo               string = "getinfo"
	cCommandGetStakingInfo        string = "getstakinginfo"
	cCommandListReceivedByAddress string = "listreceivedbyaddress"
	cCommandListTransactions      string = "listtransactions"
	cCommandGetNetworkInfo        string = "getnetworkinfo"
	cCommandGetNewAddress         string = "getnewaddress"
	cCommandGetWalletInfo         string = "getwalletinfo"
	cCommandSendToAddress         string = "sendtoaddress"
	cCommandMNSyncStatus1         string = "mnsync"
	cCommandMNSyncStatus2         string = "status"
	cCommandDumpHDInfo            string = "dumphdinfo" // ./divi-cli dumphdinfo
)

type LitecoinPlus struct {
	RPCUser     string
	RPCPassword string
	IPAddress   string
	Port        string
}

var gLastBCSyncPos float64 = 0

func (l LitecoinPlus) Bootstrap(rpcUser, rpcPassword, ip, port string) {
	l.RPCUser = rpcUser
	l.RPCPassword = rpcPassword
	l.IPAddress = ip
	if port == "" {
		l.Port = cRPCPort
	} else {
		l.Port = port
	}
}

func (l LitecoinPlus) AbbreviatedCoinName() string {
	return cCoinNameAbbrev
}

func (l LitecoinPlus) AllBinaryFilesExist(dir string) (bool, error) {
	if runtime.GOOS == "windows" {
		if !fileutils.FileExists(dir + cDaemonFileWin) {
			return false, nil
		}
	} else {
		if !fileutils.FileExists(dir + cDaemonFileLin) {
			return false, nil
		}
	}

	return true, nil
}

func (l LitecoinPlus) AnyAddresses(auth *models.CoinAuth) (bool, error) {
	addresses, err := l.ListReceivedByAddress(auth, false)
	if err != nil {
		return false, err
	}
	if len(addresses.Result) > 0 {
		return true, nil
	}
	return false, nil
}

// BlockchainDataExists - Returns true if the Blockchain data exists for the specified coin
func (l LitecoinPlus) BlockchainDataExists() (bool, error) {
	coinDir, err := l.HomeDirFullPath()
	if err != nil {
		return false, errors.New("unable to HomeDirFullPath - BlockchainDataExists")
	}

	// If the "blocks" directory already exists, return.
	if _, err := os.Stat(coinDir + "blocks"); !os.IsNotExist(err) {
		err := errors.New("The directory: " + coinDir + "blocks already exists")
		return true, err
	}

	// If the "chainstate" directory already exists, return
	if _, err := os.Stat(coinDir + "chainstate"); !os.IsNotExist(err) {
		err := errors.New("The directory: " + coinDir + "chainstate already exists")
		return true, err
	}
	return false, nil
}

func (l LitecoinPlus) BlockchainInfo(auth *models.CoinAuth) (models.DiviBlockchainInfo, error) {
	var respStruct models.DiviBlockchainInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getblockchaininfo\",\"params\":[]}")
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

func (l LitecoinPlus) BlockchainIsSynced(coinAuth *models.CoinAuth) (bool, error) {
	bci, err := l.BlockchainInfo(coinAuth)
	if err != nil {
		return false, err
	}

	if bci.Result.Verificationprogress > 0.99999 {
		return true, nil
	}

	return false, nil
}

func (l LitecoinPlus) ConfFile() string {
	return cConfFile
}

func (l LitecoinPlus) CoinName() string {
	return cCoinName
}

func (l LitecoinPlus) CoinNameAbbrev() string {
	return cCoinNameAbbrev
}

func (l LitecoinPlus) DaemonFilename() string {
	if runtime.GOOS == "windows" {
		return cDaemonFileWin
	}

	return cDaemonFileLin
}

func (l LitecoinPlus) DaemonRunning() (bool, error) {
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

//func (l LitecoinPlus) DownloadBlockchain() error {
//	coinDir, err := l.HomeDirFullPath()
//	if err != nil {
//		return errors.New("unable to get HomeDirFullPath: " + err.Error())
//	}
//	bcsFileExists := fileutils.FileExists(coinDir + cDownloadFileBS)
//	if !bcsFileExists {
//		// Then download the file.
//		if err := rjminternet.DownloadFile(coinDir, cDownloadURLBS+cDownloadFileBS); err != nil {
//			return fmt.Errorf("unable to download file: %v - %v", cDownloadURLBS, err)
//		}
//	}
//	return nil
//}

// DownloadCoin - Downloads the Syscoin files into the spcified location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (l LitecoinPlus) DownloadCoin(location string) error {
	var fullFilePath, fullFileDLURL string

	switch runtime.GOOS {
	case "windows":
		fullFilePath = location + cDownloadFileWindows
		fullFileDLURL = cDownloadURL + cDownloadFileWindows
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			return errors.New("arm32 is not currently supported for :" + cCoinName)
		case "arm64":
			return errors.New("arm64 is not currently supported for :" + cCoinName)
		case "386":
			return errors.New("linux 386 is not currently supported for :" + cCoinName)
		case "amd64":
			fullFilePath = location + cDownloadFileLinux
			fullFileDLURL = cDownloadURL + cDownloadFileLinux
		}
	}

	if err := rjminternet.DownloadFile(fullFilePath, fullFileDLURL); err != nil {
		return fmt.Errorf("unable to download file: %v - %v", fullFilePath+fullFileDLURL, err)
	}

	// Unarchive the files
	if err := l.unarchiveFile(fullFilePath, location); err != nil {
		return err
	}
	return nil
}

func (l LitecoinPlus) HomeDir() string {
	if runtime.GOOS == "windows" {
		return cHomeDirWin
	} else {
		return cHomeDir
	}
}

func (l LitecoinPlus) HomeDirFullPath() (string, error) {
	u, err := user.Current()
	if err != nil {
		return "", err
	}
	hd := u.HomeDir

	if runtime.GOOS == "windows" {
		return fileutils.AddTrailingSlash(hd) + "appdata\\roaming\\" + fileutils.AddTrailingSlash(cHomeDirWin), nil
	} else {
		return fileutils.AddTrailingSlash(hd) + fileutils.AddTrailingSlash(cHomeDir), nil
	}
}

func (l LitecoinPlus) Info(auth *models.CoinAuth) (models.DiviGetInfo, string, error) {
	var respStruct models.DiviGetInfo

	for i := 1; i < 50; i++ {
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getinfo\",\"params\":[]}")
		req, err := http.NewRequest("POST", "http://"+auth.IPAddress+":"+auth.Port, body)
		if err != nil {
			return respStruct, "", err
		}
		req.SetBasicAuth(auth.RPCUser, auth.RPCPassword)
		req.Header.Set("Content-Type", "text/plain;")

		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return respStruct, "", err
		}
		defer resp.Body.Close()
		bodyResp, err := ioutil.ReadAll(resp.Body)
		if err != nil {
			return respStruct, "", err
		}

		// Check to make sure we are not loading the wallet
		if bytes.Contains(bodyResp, []byte("Loading")) ||
			bytes.Contains(bodyResp, []byte("Rewinding")) ||
			bytes.Contains(bodyResp, []byte("Verifying")) {
			// The wallet is still loading, so print message, and sleep for 3 seconds and try again..
			var errStruct models.GenericResponse
			err = json.Unmarshal(bodyResp, &errStruct)
			if err != nil {
				return respStruct, "", err
			}
			//fmt.Println("Waiting for wallet to load...")
			time.Sleep(5 * time.Second)
		} else {

			_ = json.Unmarshal(bodyResp, &respStruct)
			return respStruct, string(bodyResp), err
		}
	}
	return respStruct, "", nil
}

// Install - Puts the freshly downloaded files into their correct location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (l LitecoinPlus) Install(location string) error {

	// Copy files to correct location
	var srcPath, sfD, dirToRemove string

	switch runtime.GOOS {
	case "windows":
		srcPath = location + cDownloadFileWindows
		sfD = cDaemonFileWin
	case "linux":
		switch runtime.GOARCH {
		case "arm", "arm64":
			srcPath = location + cExtractedDirLinux + "Ubuntu 20.04 64 bits SSL1.1/"
			sfD = cDaemonFileLin
			dirToRemove = location + cExtractedDirLinux
		case "amd64":
			srcPath = location + cExtractedDirLinux + "Ubuntu 20.04 64 bits SSL1.1/"
			sfD = cDaemonFileLin
			dirToRemove = location + cExtractedDirLinux
		default:
			return errors.New("unable to determine runtime.GOARCH " + runtime.GOARCH)
		}
	default:
		return errors.New("unable to determine runtime.GOOS")
	}

	// If the coind file doesn't already exist the copy it.
	if _, err := os.Stat(location + sfD); os.IsNotExist(err) {
		if err := fileutils.FileCopy(srcPath+sfD, location+sfD, false); err != nil {
			return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+sfD, location+sfD, err)
		}
	}
	if err := os.Chmod(location+sfD, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", location+sfD, err)
	}

	if err := os.RemoveAll(dirToRemove); err != nil {
		return err
	}

	return nil
}

// func GetBalanceInCurrencyTxtDivi(currency string, wi *DiviWalletInfoRespStruct) string {
// 	tBalance := wi.Result.ImmatureBalance + wi.Result.UnconfirmedBalance + wi.Result.Balance
// 	var pricePerCoin float64
// 	var symbol string

// 	// Work out what currency
// 	switch currency {
// 	case "AUD":
// 		symbol = "$"
// 		pricePerCoin = gTicker.DIVI.Quote.USD.Price * gPricePerCoinAUD.Rates.AUD
// 	case "USD":
// 		symbol = "$"
// 		pricePerCoin = gTicker.DIVI.Quote.USD.Price
// 	case "GBP":
// 		symbol = "£"
// 		pricePerCoin = gTicker.DIVI.Quote.USD.Price * gPricePerCoinGBP.Rates.GBP
// 	default:
// 		symbol = "$"
// 		pricePerCoin = gTicker.DIVI.Quote.USD.Price
// 	}

// 	tBalanceCurrency := pricePerCoin * tBalance

// 	tBalanceCurrencyStr := humanize.FormatFloat("###,###.##", tBalanceCurrency) //humanize.Commaf(tBalanceCurrency) //FormatFloat("#,###.####", tBalanceCurrency)

// 	// Work out balance
// 	if wi.Result.ImmatureBalance > 0 {
// 		return "Incoming......... [" + symbol + tBalanceCurrencyStr + "](fg:cyan)"
// 	} else if wi.Result.UnconfirmedBalance > 0 {
// 		return "Confirming....... [" + symbol + tBalanceCurrencyStr + "](fg:yellow)"
// 	} else {
// 		return "Currency:         [" + symbol + tBalanceCurrencyStr + "](fg:green)"
// 	}
// }

//func GetBlockchainSyncTxtDivi(synced bool, bci *DiviBlockchainInfoRespStruct) string {
//	s := ConvertBCVerification(bci.Result.Verificationprogress)
//	if s == "0.0" {
//		s = ""
//	} else {
//		s = s + "%"
//	}
//
//	if !synced {
//		return "Blockchain: [" + getNextProgBCIndicator(gLastBCSyncStatus) + "syncing " + sProg + " ](fg:yellow)"
//		if bci.Result.Verificationprogress > gLastBCSyncPos {
//			gLastBCSyncPos = bci.Result.Verificationprogress
//			return "Blockchain:  [syncing " + s + " ](fg:yellow)"
//		} else {
//			gLastBCSyncPos = bci.Result.Verificationprogress
//			return "Blockchain:  [waiting " + s + " ](fg:yellow)"
//		}
//	} else {
//		return "Blockchain:  [synced " + CUtfTickBold + "](fg:green)"
//	}
//}

//func getDiviAddNodes() ([]byte, error) {
//	addNodesClient := http.Client{
//		Timeout: time.Second * 3, // Maximum of 3 secs.
//	}
//
//	req, err := http.NewRequest(http.MethodGet, cAddNodeURL, nil)
//	if err != nil {
//		return nil, err
//	}
//
//	req.Header.Set("User-Agent", "boxwallet")
//
//	res, getErr := addNodesClient.Do(req)
//	if getErr != nil {
//		return nil, err
//	}
//
//	body, readErr := ioutil.ReadAll(res.Body)
//	if readErr != nil {
//		return nil, err
//	}
//
//	return body, nil
//}

//func (d *Divi) DumpHDInfoDivi() (models.DiviDumpHDInfo, error) {
//	var respStruct models.DiviDumpHDInfo
//
//	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandDumpHDInfo + "\",\"params\":[]}")
//	req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
//	if err != nil {
//		return respStruct, err
//	}
//	req.SetBasicAuth(d.RPCUser, d.RPCPassword)
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

//func (l *LitecoinPlus) InfoUI(spin *yacspin.Spinner) (models.DiviGetInfo, string, error) {
//	var respStruct models.DiviGetInfo
//
//	for i := 1; i < 600; i++ {
//		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandGetInfo + "\",\"params\":[]}")
//		req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
//		if err != nil {
//			return respStruct, "", err
//		}
//		req.SetBasicAuth(d.RPCUser, d.RPCPassword)
//		req.Header.Set("Content-Type", "text/plain;")
//
//		resp, err := http.DefaultClient.Do(req)
//		if err != nil {
//			spin.Message(" waiting for your " + cCoinName + " wallet to respond, this could take several minutes (ctrl-c to cancel)...")
//			time.Sleep(1 * time.Second)
//		} else {
//			defer resp.Body.Close()
//			bodyResp, err := ioutil.ReadAll(resp.Body)
//			if err != nil {
//				return respStruct, "", err
//			}
//
//			// Check to make sure we are not loading the wallet
//			if bytes.Contains(bodyResp, []byte("Loading")) ||
//				bytes.Contains(bodyResp, []byte("Rescanning")) ||
//				bytes.Contains(bodyResp, []byte("Rewinding")) ||
//				bytes.Contains(bodyResp, []byte("RPC in warm-up: Calculating money supply")) ||
//				bytes.Contains(bodyResp, []byte("Verifying")) {
//				// The wallet is still loading, so print message, and sleep for 1 second and try again..
//				var errStruct models.GenericResponse
//				err = json.Unmarshal(bodyResp, &errStruct)
//				if err != nil {
//					return respStruct, "", err
//				}
//
//				if bytes.Contains(bodyResp, []byte("Loading")) {
//					spin.Message(" Your " + cCoinName + " wallet is *Loading*, this could take a while...")
//				} else if bytes.Contains(bodyResp, []byte("Rescanning")) {
//					spin.Message(" Your " + cCoinName + " wallet is *Rescanning*, this could take a while...")
//				} else if bytes.Contains(bodyResp, []byte("Rewinding")) {
//					spin.Message(" Your " + cCoinName + " wallet is *Rewinding*, this could take a while...")
//				} else if bytes.Contains(bodyResp, []byte("Verifying")) {
//					spin.Message(" Your " + cCoinName + " wallet is *Verifying*, this could take a while...")
//				} else if bytes.Contains(bodyResp, []byte("Calculating money supply")) {
//					spin.Message(" Your " + cCoinName + " wallet is *Calculating money supply*, this could take a while...")
//				}
//				time.Sleep(1 * time.Second)
//			} else {
//				_ = json.Unmarshal(bodyResp, &respStruct)
//				return respStruct, string(bodyResp), err
//			}
//		}
//	}
//	return respStruct, "", nil
//}

func (l LitecoinPlus) ListReceivedByAddress(coinAuth *models.CoinAuth, includeZero bool) (models.DiviListReceivedByAddress, error) {
	var respStruct models.DiviListReceivedByAddress

	var s string
	if includeZero {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, true]}"
	} else {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, false]}"
	}
	body := strings.NewReader(s)
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

func (l LitecoinPlus) ListTransactions(auth *models.CoinAuth) (models.DiviListTransactions, error) {
	var respStruct models.DiviListTransactions

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandListTransactions + "\",\"params\":[]}")
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

func (l LitecoinPlus) NetworkDifficultyInfo() (float64, float64, error) {
	// https://chainz.cryptoid.info/ftc/api.dws?q=getdifficulty

	resp, err := http.Get("https://chainz.cryptoid.info/" + strings.ToLower(l.CoinNameAbbrev()) + "/api.dws?q=getdifficulty")
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

func (l LitecoinPlus) NewAddress(auth *models.CoinAuth) (models.DiviGetNewAddress, error) {
	var respStruct models.DiviGetNewAddress

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getnewaddress\",\"params\":[]}")
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

//func GetNetworkDifficultyTxtDivi(difficulty float64) string {
//	var s string
//	if difficulty > 1000 {
//		s = humanize.FormatFloat("#.#", difficulty/1000) + "k"
//	} else {
//		s = humanize.Ftoa(difficulty)
//	}
//	if difficulty > 6000 {
//		return "Difficulty:  [" + s + "](fg:green)"
//	} else if difficulty > 3000 {
//		return "[Difficulty:  " + s + "](fg:yellow)"
//	} else {
//		return "[Difficulty:  " + s + "](fg:red)"
//	}
//}

func (l LitecoinPlus) RPCDefaultUsername() string {
	return cRPCUser
}

func (l LitecoinPlus) RPCDefaultPort() string {
	return cRPCPort
}

func (l LitecoinPlus) StakingStatus(auth *models.CoinAuth) (models.DiviStakingStatus, error) {
	var respStruct models.DiviStakingStatus

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getstakingstatus\",\"params\":[]}")
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

func (l LitecoinPlus) SendToAddress(coinAuth *models.CoinAuth, address string, amount float32) (returnResp models.GenericResponse, err error) {
	var respStruct models.GenericResponse

	sAmount := fmt.Sprintf("%f", amount) // sAmount == "123.456000"

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + models.CCommandSendToAddress + "\",\"params\":[\"" + address + "\"," + sAmount + "]}")
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

func (l LitecoinPlus) StartDaemon(displayOutput bool, appFolder string, auth *models.CoinAuth) error {
	b, _ := l.DaemonRunning()
	if b {
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
		//stdout, err := cmdRun.StdoutPipe()
		//if err != nil {
		//	return err
		//}
		if err := cmdRun.Start(); err != nil {
			return err
		}
		if displayOutput {
			fmt.Println(cCoinName + " server starting")
		}

	}

	return nil
}

func (l LitecoinPlus) StopDaemon(auth *models.CoinAuth) error {
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
	//bodyResp, err := ioutil.ReadAll(resp.Body)
	//if err != nil {
	//	return err
	//}
	//err = json.Unmarshal(bodyResp, &respStruct)
	//if err != nil {
	//	return err
	//}

	return nil
}

func (l LitecoinPlus) TipAddress() string {
	return cTipAddress
}

func (l LitecoinPlus) WalletAddress(auth *models.CoinAuth) (string, error) {
	var sAddress string
	addresses, _ := l.ListReceivedByAddress(auth, true)
	if len(addresses.Result) > 0 {
		sAddress = addresses.Result[0].Address
	} else {
		r, err := l.NewAddress(auth)
		if err != nil {
			return "", err
		}
		sAddress = r.Result
	}
	return sAddress, nil
}

func (l LitecoinPlus) WalletEncrypt(coinAuth *models.CoinAuth, pw string) (be.GenericRespStruct, error) {
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

func (l LitecoinPlus) WalletInfo(auth *models.CoinAuth) (models.DiviWalletInfo, error) {
	var respStruct models.DiviWalletInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandGetWalletInfo + "\",\"params\":[]}")
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

func (l LitecoinPlus) WalletLoadingStatus(auth *models.CoinAuth) models.WLSType {
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

func (l LitecoinPlus) WalletNeedsEncrypting(coinAuth *models.CoinAuth) (bool, error) {
	wi, err := l.WalletInfo(coinAuth)
	if err != nil {
		return true, errors.New("Unable to perform WalletInfo " + err.Error())
	}

	if wi.Result.EncryptionStatus == CWalletESUnencrypted {
		return true, nil
	}

	return false, nil
}

func (l LitecoinPlus) WalletResync(appFolder string) error {
	daemonRunning, err := l.DaemonRunning()
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

func (l LitecoinPlus) WalletSecurityState(coinAuth *models.CoinAuth) (models.WEType, error) {
	wi, err := l.WalletInfo(coinAuth)
	if err != nil {
		return models.WETUnknown, errors.New("Unable to GetWalletSecurityState: " + err.Error())
	}

	if wi.Result.EncryptionStatus == CWalletESLocked {
		return models.WETLocked, nil
	} else if wi.Result.EncryptionStatus == CWalletESUnlocked {
		return models.WETUnlocked, nil
	} else if wi.Result.EncryptionStatus == CWalletESUnlockedForStaking {
		return models.WETUnlockedForStaking, nil
	} else if wi.Result.EncryptionStatus == CWalletESUnencrypted {
		return models.WETUnencrypted, nil
	} else {
		return models.WETUnknown, nil
	}
}

func (l LitecoinPlus) WalletUnlockFS(coinAuth *models.CoinAuth, pw string) error {
	var respStruct be.GenericRespStruct
	var body *strings.Reader

	body = strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",9999999,true]}")

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
	if err != nil || respStruct.Error != nil {
		return err
	}
	return nil
}

//func (l LitecoinPlus) UnarchiveBlockchainSnapshot() error {
//	coinDir, err := l.HomeDirFullPath()
//	if err != nil {
//		return errors.New("unable to get HomeDirFul - " + err.Error())
//	}
//
//	// First, check to make sure that both the blockchain folders don't already exist. (blocks, chainstate)
//	bcsFileExists := fileutils.FileExists(coinDir + cDownloadFileBS)
//	if !bcsFileExists {
//		return errors.New("unable to find the snapshot file: " + coinDir + cDownloadFileBS)
//	}
//
//	// Now extract it straight into the ~/.divi folder
//	if err := archiver.Unarchive(coinDir+cDownloadFileBS, coinDir); err != nil {
//		return errors.New("unable to unarchive file: " + coinDir + cDownloadFileBS + " " + err.Error())
//	}
//	return nil
//}

func (l LitecoinPlus) WalletUnlock(coinAuth *models.CoinAuth, pw string) error {
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

func (l LitecoinPlus) UpdateTickerInfo() (ticker models.DiviTicker, err error) {
	resp, err := http.Get("https://ticker.neist.io/DIVI")
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

func (l *LitecoinPlus) unarchiveFile(fullFilePath, location string) error {
	if err := archiver.Unarchive(fullFilePath, location); err != nil {
		return fmt.Errorf("unable to unarchive file: %v - %v", fullFilePath, err)
	}
	switch runtime.GOOS {
	case "windows":
		defer os.RemoveAll(location + cDownloadFileWindows)
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			return errors.New("arm32 is not currently supported for :" + cCoinName)
		case "arm64":
			return errors.New("arm64 is not currently supported for :" + cCoinName)
		case "386":
			return errors.New("linux 386 is not currently supported for :" + cCoinName)
		case "amd64":
			defer os.RemoveAll(location + cDownloadFileLinux)
		}
	}

	defer os.Remove(fullFilePath)

	return nil
}
