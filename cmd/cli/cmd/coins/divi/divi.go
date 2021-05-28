package bend

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
	"runtime"
	"strings"
	"time"

	"github.com/mholt/archiver/v3"
	"github.com/theckman/yacspin"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/coins"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/models"
	"richardmace.co.uk/boxwallet/cmd/cli/cmd/rjminternet"
)

const (
	cAddNodeURL string = "https://api.diviproject.org/v1/addnode"

	cCoinName       string = "DIVI"
	cCoinNameAbbrev string = "DIVI"

	cHomeDir    string = ".divi"
	cHomeDirWin string = "DIVI"

	cCoreVersion         string = "2.0.1"
	cDownloadFileArm32          = "divi-" + cCoreVersion + "-RPi2.tar.gz"
	cDownloadFileLinux          = "divi-" + cCoreVersion + "-x86_64-linux.tar.gz"
	cDownloadFileWindows        = "divi-" + cCoreVersion + "-win64.zip"
	cDownloadFileBS      string = "DIVI-snapshot.zip"

	cExtractedDirLinux   = "divi-" + cCoreVersion + "/"
	cExtractedDirWindows = "divi-" + cCoreVersion + "\\"

	cDownloadURL          = "https://github.com/DiviProject/Divi/releases/download/v" + cCoreVersion + "/"
	cDownloadURLBS string = "https://snapshots.diviproject.org/dist/"

	cConfFile      string = "divi.conf"
	cCliFile       string = "divi-cli"
	cCliFileWin    string = "divi-cli.exe"
	cDaemonFileLin string = "divid"
	cDaemonFileWin string = "divid.exe"
	cTxFile        string = "divi-tx"
	cTxFileWin     string = "divi-tx.exe"

	// divi.conf file constants.
	cRPCUser string = "divirpc"
	cRPCPort string = "51473"

	cTipAddress string = "DGvhjUXznuDyALk9zX4Y3ko4QQTmRhF7jZ"

	// Wallet encryption status
	cWalletESUnlockedForStaking = "unlocked-for-staking"
	cWalletESLocked             = "locked"
	cWalletESUnlocked           = "unlocked"
	cWalletESUnencrypted        = "unencrypted"

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

type Divi struct {
	RPCUser     string
	RPCPassword string
	IPAddress   string
	Port        string
}

var gLastBCSyncPos float64 = 0
var ticker models.DiviTicker

func (d Divi) BootStrap(rpcUser, rpcPassword, ip, port string) {
	d.RPCUser = rpcUser
	d.RPCPassword = rpcPassword
	d.IPAddress = ip
	if port == "" {
		d.Port = cRPCPort
	} else {
		d.Port = port
	}
}

func (d Divi) AbbreviatedCoinName() string {
	return cCoinNameAbbrev
}

func (d Divi) AddNodesAlreadyExist() (bool, error) {
	var exists bool

	exists, err := coins.StringExistsInFile("addnode=", d.HomeDir()+cConfFile)
	if err != nil {
		return false, nil
	}

	if exists {
		return true, nil
	}
	return false, nil
}

func (d *Divi) AddAddNodesIfRequired() error {
	doExist, err := d.AddNodesAlreadyExist()
	if err != nil {
		return err
	}
	if !doExist {
		fullPath, err := d.HomeDirFullPath()
		if err != nil {
			return err
		}
		if err := os.MkdirAll(fullPath, os.ModePerm); err != nil {
			return fmt.Errorf("unable to make directory - %v", err)
		}

		var addnodes []byte
		var sAddnodes string

		addnodes, err = getDiviAddNodes()
		if err != nil {
			return fmt.Errorf("unable to getDiviAddNodes - %v", err)
		}

		if err := coins.WriteTextToFile(fullPath+cConfFile, sAddnodes); err != nil {
			return fmt.Errorf("unable to write addnodes to file - %v", err)
		}

		sAddnodes = string(addnodes[:])
		if !strings.Contains(sAddnodes, "addnode") {
			return fmt.Errorf("unable to retrieve addnodes, please try again")
		}

		if err := coins.WriteTextToFile(fullPath+cConfFile, sAddnodes); err != nil {
			return fmt.Errorf("unable to write addnodes to file - %v", err)
		}

	}
	return nil
}

func (d Divi) AllBinaryFilesExist(dir string) (bool, error) {
	if runtime.GOOS == "windows" {
		if !coins.FileExists(dir + cCliFileWin) {
			return false, nil
		}
		if !coins.FileExists(dir + cDaemonFileWin) {
			return false, nil
		}
		if !coins.FileExists(dir + cTxFileWin) {
			return false, nil
		}
	} else {
		if !coins.FileExists(dir + cCliFile) {
			return false, nil
		}
		if !coins.FileExists(dir + cDaemonFileLin) {
			return false, nil
		}
		if !coins.FileExists(dir + cTxFile) {
			return false, nil
		}
	}
	return true, nil
}

// BlockchainDataExists - Returns true if the Blockchain data exists for the specified coin.
func (d Divi) BlockchainDataExists() (bool, error) {
	coinDir, err := d.HomeDirFullPath()
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

func (d Divi) ConfFile() string {
	return cConfFile
}

func (d Divi) CoinName() string {
	return cCoinName
}

func (d Divi) CoinNameAbbrev() string {
	return cCoinNameAbbrev
}

func (d Divi) DownloadBlockchain() error {
	coinDir, err := d.HomeDirFullPath()
	if err != nil {
		return errors.New("unable to get HomeDirFullPath: " + err.Error())
	}
	bcsFileExists := coins.FileExists(coinDir + cDownloadFileBS)
	if !bcsFileExists {
		// Then download the file.
		if err := rjminternet.DownloadFile(coinDir, cDownloadURLBS+cDownloadFileBS); err != nil {
			return fmt.Errorf("unable to download file: %v - %v", cDownloadURLBS, err)
		}
	}
	return nil
}

// DownloadCoin - Downloads the Syscoin files into the spcified location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (d Divi) DownloadCoin(location string) error {
	var fullFilePath, fullFileDLURL string

	switch runtime.GOOS {
	case "windows":
		fullFilePath = location + cDownloadFileWindows
		fullFileDLURL = cDownloadURL + cDownloadFileWindows
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			fullFilePath = location + cDownloadFileArm32
			fullFileDLURL = cDownloadURL + cDownloadFileArm32
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
	if err := d.unarchiveFile(fullFilePath, location); err != nil {
		return err
	}
	return nil
}

func (d Divi) HomeDir() string {
	if runtime.GOOS == "windows" {
		return cHomeDirWin
	} else {
		return cHomeDir
	}
}

func (d Divi) HomeDirFullPath() (string, error) {
	u, err := user.Current()
	if err != nil {
		return "", err
	}
	hd := u.HomeDir

	if runtime.GOOS == "windows" {
		return coins.AddTrailingSlash(hd) + "appdata\\roaming\\" + coins.AddTrailingSlash(cHomeDirWin), nil
	} else {
		return coins.AddTrailingSlash(hd) + coins.AddTrailingSlash(cHomeDir), nil
	}
}

// Install - Puts the freshly downloaded files into their correct location.
// "location" should just be the AppBinaryFolder ~/.boxwallet
func (d Divi) Install(location string) error {

	// Copy files to correct location
	var srcPath, sfCLI, sfD, sfTX, dirToRemove string

	switch runtime.GOOS {
	case "windows":
		srcPath = location + cDownloadFileWindows
		sfCLI = cCliFileWin
		sfD = cDaemonFileWin
		sfTX = cTxFileWin
	case "linux":
		switch runtime.GOARCH {
		case "arm", "arm64":
			srcPath = location + cExtractedDirLinux + "bin/"
			sfCLI = cCliFile
			sfD = cDaemonFileLin
			sfTX = cTxFile
			dirToRemove = location + cExtractedDirLinux
		case "amd64":
			srcPath = location + cExtractedDirLinux + "bin/"
			sfCLI = cCliFile
			sfD = cDaemonFileLin
			sfTX = cTxFile
			dirToRemove = location + cExtractedDirLinux
		default:
			return errors.New("unable to determine runtime.GOARCH " + runtime.GOARCH)
		}
	default:
		return errors.New("unable to determine runtime.GOOS")
	}

	// If the coin-cli file doesn't already exists the copy it.
	if _, err := os.Stat(location + sfCLI); os.IsNotExist(err) {
		if err := coins.FileCopy(srcPath+sfCLI, location+sfCLI, false); err != nil {
			return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+sfCLI, location+sfCLI, err)
		}
	}
	if err := os.Chmod(location+sfCLI, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", location+sfCLI, err)
	}

	// If the coind file doesn't already exists the copy it.
	if _, err := os.Stat(location + sfD); os.IsNotExist(err) {
		if err := coins.FileCopy(srcPath+sfD, location+sfD, false); err != nil {
			return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+sfD, location+sfD, err)
		}
	}
	if err := os.Chmod(location+sfD, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", location+sfD, err)
	}

	// If the coitx file doesn't already exists the copy it.
	if _, err := os.Stat(location + sfTX); os.IsNotExist(err) {
		if err := coins.FileCopy(srcPath+sfTX, location+sfTX, false); err != nil {
			return fmt.Errorf("unable to copyFile from: %v to %v - %v", srcPath+sfTX, location+sfTX, err)
		}
	}
	if err := os.Chmod(location+sfTX, 0777); err != nil {
		return fmt.Errorf("unable to chmod file: %v - %v", location+sfTX, err)
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

func (d *Divi) BlockchainInfoDivi() (models.DiviBlockchainInfo, error) {
	var respStruct models.DiviBlockchainInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getblockchaininfo\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(d.RPCUser, d.RPCPassword)
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

func getDiviAddNodes() ([]byte, error) {
	addNodesClient := http.Client{
		Timeout: time.Second * 3, // Maximum of 3 secs.
	}

	req, err := http.NewRequest(http.MethodGet, cAddNodeURL, nil)
	if err != nil {
		return nil, err
	}

	req.Header.Set("User-Agent", "boxwallet")

	res, getErr := addNodesClient.Do(req)
	if getErr != nil {
		return nil, err
	}

	body, readErr := ioutil.ReadAll(res.Body)
	if readErr != nil {
		return nil, err
	}

	return body, nil
}

func (d *Divi) DumpHDInfoDivi() (models.DiviDumpHDInfo, error) {
	var respStruct models.DiviDumpHDInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandDumpHDInfo + "\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(d.RPCUser, d.RPCPassword)
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

func (d *Divi) Info() (models.DiviGetInfo, error) {
	var respStruct models.DiviGetInfo

	for i := 1; i < 50; i++ {
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getinfo\",\"params\":[]}")
		req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
		if err != nil {
			return respStruct, err
		}
		req.SetBasicAuth(d.RPCUser, d.RPCPassword)
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
			bytes.Contains(bodyResp, []byte("Rewinding")) ||
			bytes.Contains(bodyResp, []byte("Verifying")) {
			// The wallet is still loading, so print message, and sleep for 3 seconds and try again..
			var errStruct models.GenericResponse
			err = json.Unmarshal(bodyResp, &errStruct)
			if err != nil {
				return respStruct, err
			}
			//fmt.Println("Waiting for wallet to load...")
			time.Sleep(5 * time.Second)
		} else {

			_ = json.Unmarshal(bodyResp, &respStruct)
			return respStruct, err
		}
	}
	return respStruct, nil
}

func (d *Divi) InfoUI(spin *yacspin.Spinner) (models.DiviGetInfo, string, error) {
	var respStruct models.DiviGetInfo

	for i := 1; i < 600; i++ {
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandGetInfo + "\",\"params\":[]}")
		req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
		if err != nil {
			return respStruct, "", err
		}
		req.SetBasicAuth(d.RPCUser, d.RPCPassword)
		req.Header.Set("Content-Type", "text/plain;")

		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			spin.Message(" waiting for your " + cCoinName + " wallet to respond, this could take several minutes (ctrl-c to cancel)...")
			time.Sleep(1 * time.Second)
		} else {
			defer resp.Body.Close()
			bodyResp, err := ioutil.ReadAll(resp.Body)
			if err != nil {
				return respStruct, "", err
			}

			// Check to make sure we are not loading the wallet
			if bytes.Contains(bodyResp, []byte("Loading")) ||
				bytes.Contains(bodyResp, []byte("Rescanning")) ||
				bytes.Contains(bodyResp, []byte("Rewinding")) ||
				bytes.Contains(bodyResp, []byte("RPC in warm-up: Calculating money supply")) ||
				bytes.Contains(bodyResp, []byte("Verifying")) {
				// The wallet is still loading, so print message, and sleep for 1 second and try again..
				var errStruct models.GenericResponse
				err = json.Unmarshal(bodyResp, &errStruct)
				if err != nil {
					return respStruct, "", err
				}

				if bytes.Contains(bodyResp, []byte("Loading")) {
					spin.Message(" Your " + cCoinName + " wallet is *Loading*, this could take a while...")
				} else if bytes.Contains(bodyResp, []byte("Rescanning")) {
					spin.Message(" Your " + cCoinName + " wallet is *Rescanning*, this could take a while...")
				} else if bytes.Contains(bodyResp, []byte("Rewinding")) {
					spin.Message(" Your " + cCoinName + " wallet is *Rewinding*, this could take a while...")
				} else if bytes.Contains(bodyResp, []byte("Verifying")) {
					spin.Message(" Your " + cCoinName + " wallet is *Verifying*, this could take a while...")
				} else if bytes.Contains(bodyResp, []byte("Calculating money supply")) {
					spin.Message(" Your " + cCoinName + " wallet is *Calculating money supply*, this could take a while...")
				}
				time.Sleep(1 * time.Second)
			} else {
				_ = json.Unmarshal(bodyResp, &respStruct)
				return respStruct, string(bodyResp), err
			}
		}
	}
	return respStruct, "", nil
}

func (d *Divi) MNSyncStatus() (models.DiviMNSyncStatus, error) {
	var respStruct models.DiviMNSyncStatus

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"mnsync\",\"params\":[\"status\"]}")
	req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(d.RPCUser, d.RPCPassword)
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

func (d *Divi) NewAddress() (models.DiviGetNewAddress, error) {
	var respStruct models.DiviGetNewAddress

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getnewaddress\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(d.RPCUser, d.RPCPassword)
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

func (d Divi) RPCDefaultUsername() string {
	return cRPCUser
}

func (d Divi) RPCDefaultPort() string {
	return cRPCPort
}

func (d *Divi) StakingStatus() (models.DiviStakingStatus, error) {
	var respStruct models.DiviStakingStatus

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getstakingstatus\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(d.RPCUser, d.RPCPassword)
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

func (d *Divi) WalletInfo() (models.DiviWalletInfo, error) {
	var respStruct models.DiviWalletInfo

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandGetWalletInfo + "\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(d.RPCUser, d.RPCPassword)
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

func (d *Divi) WalletSecurityState() (models.WEType, error) {
	wi, err := d.WalletInfo()
	if err != nil {
		return models.WETUnknown, errors.New("Unable to GetWalletSecurityState: " + err.Error())
	}

	if wi.Result.EncryptionStatus == cWalletESLocked {
		return models.WETLocked, nil
	} else if wi.Result.EncryptionStatus == cWalletESUnlocked {
		return models.WETUnlocked, nil
	} else if wi.Result.EncryptionStatus == cWalletESUnlockedForStaking {
		return models.WETUnlockedForStaking, nil
	} else if wi.Result.EncryptionStatus == cWalletESUnencrypted {
		return models.WETUnencrypted, nil
	} else {
		return models.WETUnknown, nil
	}
}

func (d *Divi) ListReceivedByAddressDivi(includeZero bool) (models.DiviListReceivedByAddress, error) {
	var respStruct models.DiviListReceivedByAddress

	var s string
	if includeZero {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, true]}"
	} else {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, false]}"
	}
	body := strings.NewReader(s)
	req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(d.RPCUser, d.RPCPassword)
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

func (d *Divi) ListTransactionsDivi() (models.DiviListTransactions, error) {
	var respStruct models.DiviListTransactions

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandListTransactions + "\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(d.RPCUser, d.RPCPassword)
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

func (d *Divi) SendToAddress(address string, amount float32) (returnResp models.GenericResponse, err error) {
	var respStruct models.GenericResponse

	sAmount := fmt.Sprintf("%f", amount) // sAmount == "123.456000"

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandSendToAddress + "\",\"params\":[\"" + address + "\"," + sAmount + "]}")
	req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(d.RPCUser, d.RPCPassword)
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

func (d *Divi) StartDaemon(dir string, displayOutput bool) error {
	if runtime.GOOS == "windows" {
		fp := dir + cDaemonFileWin
		cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
		if err := cmd.Run(); err != nil {
			return err
		}
	} else {
		if displayOutput {
			fmt.Println("Attempting to run the " + cCoinName + " daemon...")
		}

		cmdRun := exec.Command(dir + cDaemonFileLin)
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

func (d *Divi) StopDaemon(ip, port, rpcUser, rpcPassword string, displayOut bool) (models.GenericResponse, error) {
	var respStruct models.GenericResponse

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"stop\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+ip+":"+port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(rpcUser, rpcPassword)
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

func (d Divi) TipAddress() string {
	return cTipAddress
}

func (d Divi) UnarchiveBlockchainSnapshot() error {
	coinDir, err := d.HomeDirFullPath()
	if err != nil {
		return errors.New("unable to get HomeDirFul - " + err.Error())
	}

	// First, check to make sure that both the blockchain folders don't already exist. (blocks, chainstate)
	bcsFileExists := coins.FileExists(coinDir + cDownloadFileBS)
	if !bcsFileExists {
		return errors.New("unable to find the snapshot file: " + coinDir + cDownloadFileBS)
	}

	// Now extract it straight into the ~/.divi folder
	if err := archiver.Unarchive(coinDir+cDownloadFileBS, coinDir); err != nil {
		return errors.New("unable to unarchive file: " + coinDir + cDownloadFileBS + " " + err.Error())
	}
	return nil
}

func (d *Divi) UnlockWallet(pw string) error {
	var respStruct models.GenericResponse

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",0]}")
	req, err := http.NewRequest("POST", "http://"+d.IPAddress+":"+d.Port, body)
	if err != nil {
		return err
	}
	req.SetBasicAuth(d.RPCUser, d.RPCPassword)
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

func (d *Divi) UpdateTickerInfo() error {
	resp, err := http.Get("https://ticker.neist.io/DIVI")
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	err = json.Unmarshal(body, &ticker)
	if err != nil {
		return err
	}
	return errors.New("unable to updateTicketInfo")
}

func (d *Divi) unarchiveFile(fullFilePath, location string) error {
	if err := archiver.Unarchive(fullFilePath, location); err != nil {
		return fmt.Errorf("unable to unarchive file: %v - %v", fullFilePath, err)
	}
	switch runtime.GOOS {
	case "windows":
		defer os.RemoveAll(location + cDownloadFileWindows)
	case "linux":
		switch runtime.GOARCH {
		case "arm":
			defer os.RemoveAll(location + cDownloadFileArm32)
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
