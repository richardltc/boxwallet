package bend

import (
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

type DownloadCoin interface {
	DownloadCoin(location string) error
}

type InstallCoin interface {
	Install(location string) error
}

const (
	CAppName        string = "BoxWallet"
	CUpdaterAppName string = "bwupdater"
	CBWAppVersion   string = "0.41.2"
	CAppFilename    string = "boxwallet"
	CAppFilenameWin string = "boxwallet.exe"
	CAppLogfile     string = "boxwallet.log"

	cAppWorkingDirLin string = ".boxwallet"
	cAppWorkingDirWin string = "BoxWallet"

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

	// divi-cli wallet commands
	cCommandDisplayWalletAddress string = "getaddressesbyaccount" // ./divi-cli getaddressesbyaccount ""
	cCommandDumpHDInfo           string = "dumphdinfo"            // ./divi-cli dumphdinfo
	// CCommandEncryptWallet - Needed by dash command
	CCommandEncryptWallet  string = "encryptwallet"    // ./divi-cli encryptwallet “a_strong_password”
	cCommandRestoreWallet  string = "-hdseed="         // ./divid -debug-hdseed=the_seed -rescan (stop divid, rename wallet.dat, then run command)
	cCommandUnlockWallet   string = "walletpassphrase" // ./divi-cli walletpassphrase “password” 0
	cCommandUnlockWalletFS string = "walletpassphrase" // ./divi-cli walletpassphrase “password” 0 true
	cCommandLockWallet     string = "walletlock"       // ./divi-cli walletlock

	// Divid Responses
	cDiviDNotRunningError     string = "error: couldn't connect to server"
	cDiviDDIVIServerStarting  string = "DIVI server starting"
	cDividRespWalletEncrypted string = "wallet encrypted"

	cGoDiviExportPath         string = "export PATH=$PATH:"
	CUninstallConfirmationStr string = "Confirm"
	CSeedStoredSafelyStr      string = "Confirm"

	// CMinRequiredMemoryMB - Needed by install command
	CMinRequiredMemoryMB int = 920
	CMinRequiredSwapMB   int = 2048

	// Wallet Security Statuses - Should be types?
	CWalletStatusLocked      string = "locked"
	CWalletStatusUnlocked    string = "unlocked"
	CWalletStatusLockedAndSk string = "locked-anonymization"
	CWalletStatusUnEncrypted string = "unencrypted"

	cRPCUserStr     string = "rpcuser"
	cRPCPasswordStr string = "rpcpassword"

	cUtfTick     string = "\u2713"
	CUtfTickBold string = "\u2714"

	cCircProg1 string = "\u25F7"
	cCircProg2 string = "\u25F6"
	cCircProg3 string = "\u25F5"
	cCircProg4 string = "\u25F4"

	cUtfLock string = "\u1F512"

	cProg1 string = "|"
	cProg2 string = "/"
	cProg3 string = "-"
	cProg4 string = "\\"
	cProg5 string = "|"
	cProg6 string = "/"
	cProg7 string = "-"
	cProg8 string = "\\"

	BUWWalletDat     string = "Backup wallet.dat"
	BUWDisplayHDSeed string = "Display recovery seed"
	BUWStoreSeed     string = "Store seed"
)

// APPType - either APPTCLI, APPTCLICompiled, APPTInstaller, APPTUpdater, APPTServer
type APPType int

const (
	// APPTCLI - e.g. boxdivi
	APPTCLI APPType = iota
	// APPTCLICompiled - e.g. cli
	APPTCLICompiled
	// APPTInstaller e.g. boxwallet-installer
	//APPTInstaller
	// APPTUpdater e.g. update-godivi
	APPTUpdater
	// APPTUpdaterCompiled e.g. updater
	APPTUpdaterCompiled
	// APPTServer e.g. boxdivis
	//APPTServer
	// APPTServerCompiled e.g. web
	//APPTServerCompiled
)

// ProjectType - To allow external to determine what kind of wallet we are working with.
type ProjectType int

const (
	PTDivi ProjectType = iota
	PTPhore
	PTPIVX
	PTTrezarcoin
	PTFeathercoin
	PTVertcoin
	PTGroestlcoin
	PTScala
	PTDeVault
	PTReddCoin
	PTRapids
	PTDigiByte
	PTDenarius
	PTSyscoin
	PTBitcoinPlus
	PTPeercoin
)

// OSType - either ostArm, ostLinux or ostWindows
type OSType int

const (
	// OSTArm - Arm
	OSTArm OSType = iota
	// OSTLinux - Linux
	OSTLinux
	// OSTWindows - Windows
	OSTWindows
)

// WEType = either wetUnencrypted, wetLocked, wetUnlocked, weUnlockedForStaking
type WEType int

const (
	WETUnencrypted WEType = iota
	WETLocked
	WETUnlocked
	WETUnlockedForStaking
	WETUnknown
)

type GenericRespStruct struct {
	Result string      `json:"result"`
	Error  interface{} `json:"error"`
	ID     string      `json:"id"`
}

type GetAddressesByAccountRespStruct struct {
	Result []string    `json:"result"`
	Error  interface{} `json:"error"`
	ID     string      `json:"id"`
}

type GetInfoRespStruct struct {
	Result struct {
		Version         string  `json:"version"`
		Protocolversion int     `json:"protocolversion"`
		Walletversion   int     `json:"walletversion"`
		Balance         float64 `json:"balance"`
		Blocks          int     `json:"blocks"`
		Timeoffset      int     `json:"timeoffset"`
		Connections     int     `json:"connections"`
		Proxy           string  `json:"proxy"`
		Difficulty      float64 `json:"difficulty"`
		Testnet         bool    `json:"testnet"`
		Moneysupply     float64 `json:"moneysupply"`
		Keypoololdest   int     `json:"keypoololdest"`
		Keypoolsize     int     `json:"keypoolsize"`
		UnlockedUntil   int     `json:"unlocked_until"`
		Paytxfee        float64 `json:"paytxfee"`
		Relayfee        float64 `json:"relayfee"`
		StakingStatus   string  `json:"staking status"`
		Errors          string  `json:"errors"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type WalletInfoPhoreRespStruct struct {
	Result struct {
		Walletversion int     `json:"walletversion"`
		Balance       float64 `json:"balance"`
		Txcount       int     `json:"txcount"`
		Keypoololdest int     `json:"keypoololdest"`
		Keypoolsize   int     `json:"keypoolsize"`
		UnlockedUntil int     `json:"unlocked_until"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type usd2AUDRespStruct struct {
	Rates struct {
		AUD float64 `json:"AUD"`
	} `json:"rates"`
	Base string `json:"base"`
	Date string `json:"date"`
}

type usd2GBPRespStruct struct {
	Rates struct {
		GBP float64 `json:"GBP"`
	} `json:"rates"`
	Base string `json:"base"`
	Date string `json:"date"`
}

type walletResponseType int

const (
	wrType walletResponseType = iota
	wrtUnknown
	wrtAllOK
	wrtNotReady
	wrtStillLoading
)

type WalletFixType int

const (
	WFType WalletFixType = iota
	WFTReIndex
	WFTReSync
)

//var gLastMNSyncStatus string = ""

// Ticker related variables
//var gGetTickerInfoCount int
//var gPricePerCoinAUD usd2AUDRespStruct
//var gPricePerCoinGBP usd2GBPRespStruct

// ConvertBCVerification - Convert Blockchain verification progress...
func ConvertBCVerification(verificationPG float64) string {
	var sProg string
	var fProg float64

	fProg = verificationPG * 100
	sProg = fmt.Sprintf("%.2f", fProg)

	return sProg
}

func getWalletResponse(sOut string) walletResponseType {
	if sOut == "" {
		return wrtNotReady
	}

	if strings.Contains(sOut, "hdseed") {
		return wrtAllOK
	}

	if strings.Contains(sOut, "wallet") {
		return wrtAllOK
	}

	return wrtUnknown
}

func runDCCommand(cmdBaseStr, cmdStr, waitingStr string, attempts int) (string, error) {
	var err error
	//var s string = waitingStr
	for i := 0; i < attempts; i++ {
		cmd := exec.Command(cmdBaseStr, cmdStr)
		out, err := cmd.CombinedOutput()

		if err == nil {
			return string(out), err
		}
		fmt.Printf("\r"+waitingStr+" %d/"+strconv.Itoa(attempts), i)

		time.Sleep(3 * time.Second)
	}

	return "", err
}

func runDCCommandWithValue(cmdBaseStr, cmdStr, valueStr, waitingStr string, attempts int) (string, error) {
	var err error
	//var s string = waitingStr
	for i := 0; i < attempts; i++ {
		cmd := exec.Command(cmdBaseStr, cmdStr, valueStr)
		out, err := cmd.CombinedOutput()

		if err == nil {
			return string(out), err
		}
		fmt.Printf("\r"+waitingStr+" %d/"+strconv.Itoa(attempts), i)
		time.Sleep(3 * time.Second)
	}

	return "", err
}

// func ShouldWeRunHealthCheck() (bool, error) {
// 	bwconf, err := GetConfigStruct("", false)
// 	if err != nil {
// 		return false, fmt.Errorf("unable to GetConfigStruct - %v", err)
// 	}

// 	t := time.Now()
// 	s := t.Format("15:04")
// 	if bwconf.LastHealthCheck == cUnknown {
// 		if bwconf.RunHealthCheckAt == s {
// 			// Run the health check
// 			return true, nil
// 		}
// 	}

// 	lrd := t.Format("2006-01-02")
// 	if lrd != bwconf.LastHealthCheck {
// 		// Check the time and run if it matches
// 		if bwconf.RunHealthCheckAt == s {
// 			// Run the health check
// 			return true, nil
// 		}
// 	}

// 	return false, nil
// }

// // StopDaemonMonero - Stops Monero based coin daemons
// func StopDaemonMonero(cliConf *ConfStruct) (XLAStopDaemonRespStruct, error) {
// 	var respStruct XLAStopDaemonRespStruct

// 	//body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"stop_daemon\",\"params\":[]}")
// 	body := strings.NewReader("")
// 	req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port+"/stop_daemon", body)
// 	if err != nil {
// 		return respStruct, err
// 	}
// 	//req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword) //
// 	req.Header.Set("Content-Type", "application/json;")

// 	resp, err := http.DefaultClient.Do(req)
// 	if err != nil {
// 		return respStruct, err
// 	}
// 	defer resp.Body.Close()
// 	bodyResp, err := ioutil.ReadAll(resp.Body)
// 	if err != nil {
// 		return respStruct, err
// 	}
// 	err = json.Unmarshal(bodyResp, &respStruct)
// 	if err != nil {
// 		return respStruct, err
// 	}
// 	return respStruct, nil
// }

func ValidateAddress(pt ProjectType, ad string) (bool, error) {
	// First, work out what the coin type is
	var err error
	switch pt {
	case PTDenarius:
		// If the length of the address is not exactly 34 characters...
		if len(ad) != 34 {
			return false, nil
		}
		sFirst := ad[0]

		// 68 = UTF for D
		if sFirst != 68 {
			return false, nil
		}
	case PTDeVault:
		// If the length of the address is not exactly 50 characters...
		if len(ad) != 50 {
			return false, nil
		}
		sFirst := ad[0]

		// 100 = UTF for d
		if sFirst != 100 {
			return false, nil
		}
	case PTDigiByte:
		// If the length of the address is not exactly 34 characters...
		//if len(ad) != 34 {
		//	return false, nil
		//}
		sFirst := ad[0]

		// 68 = UTF for D, 100 = UTF d
		if sFirst == 68 || sFirst == 100 {
			return true, nil
		}
	case PTFeathercoin:
		// It's un-clear what the address format is at present...
		return true, nil
	case PTGroestlcoin:
		// It's un-clear what the address format is at present...
		return true, nil
	case PTPhore:
		// If the length of the address is not exactly 34 characters...
		if len(ad) != 34 {
			return false, nil
		}
		sFirst := ad[0]

		// 80 = UTF for P
		if sFirst != 80 {
			return false, nil
		}
	case PTPIVX:
		// If the length of the address is not exactly 34 characters..
		if len(ad) != 34 {
			return false, nil
		}
		sFirst := ad[0]

		// 68 = UTF for D
		if sFirst != 68 {
			return false, nil
		}
	case PTRapids:
		// If the length of the address is not exactly 34 characters...
		if len(ad) != 34 {
			return false, nil
		}
		sFirst := ad[0]

		// 82 = UTF for R
		if sFirst != 82 {
			return false, nil
		}
	case PTReddCoin:
		// If the length of the address is not exactly 34 characters...
		if len(ad) != 34 {
			return false, nil
		}
		sFirst := ad[0]

		// 82 = UTF for R
		if sFirst != 82 {
			return false, nil
		}
	case PTSyscoin:
		// It's un-clear what the address format is at present...
		return true, nil
	case PTTrezarcoin:
		// If the length of the address is not exactly 34 characters...
		if len(ad) != 34 {
			return false, nil
		}
		sFirst := ad[0]

		// 84 = UTF for T
		if sFirst != 84 {
			return false, nil
		}
	case PTVertcoin:
		// It's un-clear what the address format is at present...
		return true, nil
	default:
		return false, fmt.Errorf("unable to determine ProjectType - ValidateAddress: %v", err)
	}
	return true, nil
}

// func WalletBackup(pt ProjectType) error {
// 	var abbrev, wl, destFolder string

// 	// First, work out what the coin type is
// 	var err error
// 	switch pt {
// 	case PTBitcoinPlus:
// 		abbrev = strings.ToLower(CCoinAbbrevBitcoinPlus)
// 		wl, err = GetCoinHomeFolder(APPTCLI, pt)
// 		if err != nil {
// 			return fmt.Errorf("unable to get coin home folder: %v", err)
// 		}
// 	case PTDenarius:
// 		abbrev = strings.ToLower(CCoinAbbrevDenarius)
// 		wl, err = GetCoinHomeFolder(APPTCLI, pt)
// 		if err != nil {
// 			return fmt.Errorf("unable to get coin home folder: %v", err)
// 		}
// 	case PTDeVault:
// 		abbrev = strings.ToLower(CCoinAbbrevDeVault)
// 		wl, err = GetCoinHomeFolder(APPTCLI, pt)
// 		if err != nil {
// 			return fmt.Errorf("unable to get coin home folder: %v", err)
// 		}
// 	case PTDigiByte:
// 		abbrev = strings.ToLower(CCoinAbbrevDigiByte)
// 		wl, err = GetCoinHomeFolder(APPTCLI, pt)
// 		if err != nil {
// 			return fmt.Errorf("unable to get coin home folder: %v", err)
// 		}
// 	case PTDivi:
// 		abbrev = strings.ToLower(CCoinAbbrevDivi)
// 		wl, err = GetCoinHomeFolder(APPTCLI, pt)
// 		if err != nil {
// 			return fmt.Errorf("unable to get coin home folder: %v", err)
// 		}
// 	case PTFeathercoin:
// 		abbrev = strings.ToLower(CCoinAbbrevFeathercoin)
// 		wl, err = GetCoinHomeFolder(APPTCLI, pt)
// 		if err != nil {
// 			return fmt.Errorf("unable to get coin home folder: %v", err)
// 		}
// 	case PTGroestlcoin:
// 		abbrev = strings.ToLower(CCoinAbbrevGroestlcoin)
// 		wl, err = GetCoinHomeFolder(APPTCLI, pt)
// 		if err != nil {
// 			return fmt.Errorf("unable to get coin home folder: %v", err)
// 		}
// 	case PTPhore:
// 		abbrev = strings.ToLower(CCoinAbbrevPhore)
// 		wl, err = GetCoinHomeFolder(APPTCLI, pt)
// 		if err != nil {
// 			return fmt.Errorf("unable to get coin home folder: %v", err)
// 		}
// 	case PTPIVX:
// 		abbrev = strings.ToLower(CCoinAbbrevPIVX)
// 		wl, err = GetCoinHomeFolder(APPTCLI, pt)
// 		if err != nil {
// 			return fmt.Errorf("unable to get coin home folder: %v", err)
// 		}
// 	case PTRapids:
// 		abbrev = strings.ToLower(CCoinAbbrevRapids)
// 		wl, err = GetCoinHomeFolder(APPTCLI, pt)
// 		if err != nil {
// 			return fmt.Errorf("unable to get coin home folder: %v", err)
// 		}
// 	case PTReddCoin:
// 		abbrev = strings.ToLower(CCoinAbbrevReddCoin)
// 		wl, err = GetCoinHomeFolder(APPTCLI, pt)
// 		if err != nil {
// 			return fmt.Errorf("unable to get coin home folder: %v", err)
// 		}
// 	case PTTrezarcoin:
// 		abbrev = strings.ToLower(CCoinAbbrevTrezarcoin)
// 		wl, err = GetCoinHomeFolder(APPTCLI, pt)
// 		if err != nil {
// 			return fmt.Errorf("unable to get coin home folder: %v", err)
// 		}
// 	case PTVertcoin:
// 		abbrev = strings.ToLower(CCoinAbbrevVertcoin)
// 		wl, err = GetCoinHomeFolder(APPTCLI, pt)
// 		if err != nil {
// 			return fmt.Errorf("unable to get coin home folder: %v", err)
// 		}
// 	default:
// 		return fmt.Errorf("unable to determine ProjectType - WalletBackup: %v", err)
// 	}

// 	// Make sure the coin daemon is not running
// 	isRunning, _, err := IsCoinDaemonRunning(pt)
// 	if err != nil {
// 		return fmt.Errorf("unablle to run IsCoinDaemonRunning: %v", err)
// 	}
// 	if isRunning {
// 		cdn, err := GetCoinDaemonFilename(APPTCLI, pt)
// 		if err != nil {
// 			return fmt.Errorf("unablle to run GetCoinDaemonFilename: %v", err)
// 		}
// 		return fmt.Errorf("please stop the " + cdn + " daemon first")
// 	}

// 	ex, err := os.Executable()
// 	if err != nil {
// 		return fmt.Errorf("Unable to retrieve running binary: %v ", err)
// 	}
// 	destFolder = AddTrailingSlash(filepath.Dir(ex))

// 	// Copy the wallet.dat file to the same directory that's running BoxWallet
// 	if err := BackupFile(wl, "wallet.dat", destFolder, abbrev, true); err != nil {
// 		return fmt.Errorf("Unable to perform backup of wallet.dat: %v ", err)
// 	}

// 	return nil
// }
