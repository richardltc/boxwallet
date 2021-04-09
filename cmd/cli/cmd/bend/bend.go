package bend

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/AlecAivazis/survey/v2"
	"github.com/mholt/archiver/v3"
	"io/ioutil"
	"log"
	"net/http"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/mitchellh/go-ps"
	rand "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend/rand"
)

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

var gLastMNSyncStatus string = ""

// Ticker related variables
var gGetTickerInfoCount int
var gPricePerCoinAUD usd2AUDRespStruct
var gPricePerCoinGBP usd2GBPRespStruct
var gTicker DiviTickerStruct

func AddNodesAlreadyExist() (bool, error) {
	bwconf, err := GetConfigStruct("", false) //GetCLIConfStruct()
	if err != nil {
		return false, fmt.Errorf("unable to GetConfigStruct - %v", err)
	}

	chd, _ := GetCoinHomeFolder(APPTCLI, bwconf.ProjectType)
	var exists bool

	switch bwconf.ProjectType {
	case PTDivi:
		exists, err = StringExistsInFile("addnode=", chd+cConfFileDivi)
		if err != nil {
			return false, nil
		}
	case PTRapids:
		exists, err = StringExistsInFile("addnode=", chd+CRapidsConfFile)
		if err != nil {
			return false, nil
		}
	default:
		err = errors.New("unable to determine ProjectType")
	}

	if exists {
		return true, nil
	}
	return false, nil
}

func AddAddNodesIfRequired() error {
	doExist, err := AddNodesAlreadyExist()
	if err != nil {
		return err
	}
	if !doExist {
		bwconf, err := GetConfigStruct("", false) //GetCLIConfStruct()
		if err != nil {
			return fmt.Errorf("unable to GetConfigStruct - %v", err)
		}
		chd, _ := GetCoinHomeFolder(APPTCLI, bwconf.ProjectType)
		if err := os.MkdirAll(chd, os.ModePerm); err != nil {
			return fmt.Errorf("unable to make directory - %v", err)
		}

		var addnodes []byte
		var sAddnodes string

		switch bwconf.ProjectType {
		case PTDivi:
			addnodes, err = getDiviAddNodes()
			if err != nil {
				return fmt.Errorf("unable to getDiviAddNodes - %v", err)
			}

			if err := WriteTextToFile(chd+cConfFileDivi, sAddnodes); err != nil {
				return fmt.Errorf("unable to write addnodes to file - %v", err)
			}
		case PTRapids:
			addnodes, err = getRapidsAddNodes()
			if err != nil {
				return fmt.Errorf("unable to getRapidsAddNodes - %v", err)
			}

			if err := WriteTextToFile(chd+CRapidsConfFile, sAddnodes); err != nil {
				return fmt.Errorf("unable to write addnodes to file - %v", err)
			}
		default:
			err = errors.New("unable to determine ProjectType")
		}

		sAddnodes = string(addnodes[:])
		if !strings.Contains(sAddnodes, "addnode") {
			return fmt.Errorf("unable to retrieve addnodes, please try again")
		}

		switch bwconf.ProjectType {
		case PTDivi:
			if err := WriteTextToFile(chd+cConfFileDivi, sAddnodes); err != nil {
				return fmt.Errorf("unable to write addnodes to file - %v", err)
			}
		case PTRapids:
			if err := WriteTextToFile(chd+CRapidsConfFile, sAddnodes); err != nil {
				return fmt.Errorf("unable to write addnodes to file - %v", err)
			}
		default:
			err = errors.New("unable to determine ProjectType")
		}

	}
	return nil
}

// BlockchainDataExists - Returns true if the Blockchain data exists for the specified coin.
func BlockchainDataExists(pt ProjectType) (bool, error) {
	cd, err := GetCoinHomeFolder(APPTCLI, pt)
	if err != nil {
		return false, fmt.Errorf("unable to GetCoinHomeFolder - DownloadBlockchain: %v", err)
	}

	switch pt {
	case PTDenarius:
		// If the "blk0001.dat" file already exists, return.
		if _, err := os.Stat(cd + "blk0001.dat"); !os.IsNotExist(err) {
			err := errors.New("The file: " + cd + "blk0001.dat already exists")
			return true, err
		}

		// If the "blk0002.dat" file already exists, return
		if _, err := os.Stat(cd + "blk0002.dat"); !os.IsNotExist(err) {
			err := errors.New("The file: " + cd + "blk0002.dat already exists")
			return true, err
		}
	default:
		// If the "blocks" directory already exists, return.
		if _, err := os.Stat(cd + "blocks"); !os.IsNotExist(err) {
			err := errors.New("The directory: " + cd + "blocks already exists")
			return true, err
		}

		// If the "chainstate" directory already exists, return
		if _, err := os.Stat(cd + "chainstate"); !os.IsNotExist(err) {
			err := errors.New("The directory: " + cd + "chainstate already exists")
			return true, err
		}
	}
	return false, nil
}

// ConvertBCVerification - Convert Blockchain verification progress...
func ConvertBCVerification(verificationPG float64) string {
	var sProg string
	var fProg float64

	fProg = verificationPG * 100
	sProg = fmt.Sprintf("%.2f", fProg)

	return sProg
}

func DownloadBlockchain(pt ProjectType) error {
	var cd string
	var err error

	// First, check to make sure that both the blockchain folders don't already exist. (blocks, chainstate)
	cd, err = GetCoinHomeFolder(APPTCLI, pt)
	if err != nil {
		return fmt.Errorf("unable to GetCoinHomeFolder - DownloadBlockchain: %v", err)
	}
	switch pt {
	case PTDenarius:
		switch runtime.GOARCH {
		case "arm", "arm64":
			bcsFileExists := FileExists(cd + CDFBSARMDenarius)
			if !bcsFileExists {
				// Then download the file.
				if err := DownloadFile(cd, CDownloadURLDenariusBS+CDFBSARMDenarius); err != nil {
					return fmt.Errorf("unable to download file: %v - %v", CDFBSARMDenarius, err)
				}
			}
		default:
			bcsFileExists := FileExists(cd + CDFBSDenarius)
			if !bcsFileExists {
				// Then download the file.
				if err := DownloadFile(cd, CDownloadURLDenariusBS+CDFBSDenarius); err != nil {
					return fmt.Errorf("unable to download file: %v - %v", CDFBSDenarius, err)
				}
			}
		}
	case PTDivi:
		bcsFileExists := FileExists(cd + CDFDiviBS)
		if !bcsFileExists {
			// Then download the file.
			if err := DownloadFile(cd, CDownloadURLDiviBS+CDFDiviBS); err != nil {
				return fmt.Errorf("unable to download file: %v - %v", CDownloadURLDiviBS, err)
			}
		}
	case PTReddCoin:
		bcsFileExists := FileExists(cd + CDFReddCoinBS)
		if !bcsFileExists {
			// Then download the file.
			if err := DownloadFile(cd, CDownloadURLReddCoinBS+CDFReddCoinBS); err != nil {
				return fmt.Errorf("unable to download file: %v - %v", CDownloadURLReddCoinBS, err)
			}
		}
	default:
		err := errors.New("unable to determine ProjectType - DownloadBlockchain")
		return err
	}
	return nil
}

func UnarchiveBlockchainSnapshot(pt ProjectType) error {
	var cd string
	var err error

	// First, check to make sure that both the blockchain folders don't already exist. (blocks, chainstate)
	cd, err = GetCoinHomeFolder(APPTCLI, pt)
	if err != nil {
		return fmt.Errorf("unable to GetCoinHomeFolder - UnarchiveBlockchainSnapshot: %v", err)
	}

	chdExists, err := BlockchainDataExists(pt)
	if err != nil {
		return fmt.Errorf("unable to determine if BlockchainDataExists: %v", err)
	}
	if chdExists {
		err := errors.New("blockchain data already exists")
		return err
	}
	switch pt {
	case PTDenarius:
		switch runtime.GOARCH {
		case "arm", "arm64":
			bcsFileExists := FileExists(cd + CDFBSARMDenarius)
			if !bcsFileExists {
				return fmt.Errorf("unable to find the snapshot file: %v", cd+CDFBSARMDenarius)
			}

			// Now extract it straight into the ~/.divi folder
			fmt.Println("Decompressing to " + cd + "...")
			if err := archiver.Unarchive(cd+CDFBSARMDenarius, cd); err != nil {
				return fmt.Errorf("unable to unarchive file: %v - %v", cd+CDFBSARMDenarius, err)
			}
		default:
			bcsFileExists := FileExists(cd + CDFBSDenarius)
			if !bcsFileExists {
				return fmt.Errorf("unable to find the snapshot file: %v", cd+CDFBSDenarius)
			}

			// Now extract it straight into the ~/.divi folder
			fmt.Println("Decompressing to " + cd + "...")
			if err := archiver.Unarchive(cd+CDFBSDenarius, cd); err != nil {
				return fmt.Errorf("unable to unarchive file: %v - %v", cd+CDFBSDenarius, err)
			}
		}
	case PTDivi:
		bcsFileExists := FileExists(cd + CDFDiviBS)
		if !bcsFileExists {
			return fmt.Errorf("unable to find the snapshot file: %v", cd+CDFDiviBS)
		}

		// Now extract it straight into the ~/.divi folder
		fmt.Println("Decompressing to " + cd + "...")
		if err := archiver.Unarchive(cd+CDFDiviBS, cd); err != nil {
			return fmt.Errorf("unable to unarchive file: %v - %v", cd+CDFDiviBS, err)
		}
	case PTReddCoin:
		bcsFileExists := FileExists(cd + CDFReddCoinBS)
		if !bcsFileExists {
			return fmt.Errorf("unable to find the snapshot file: %v", cd+CDFReddCoinBS)
		}

		// Now extract it straight into the ~/.reddcoin folder
		fmt.Println("Decompressing to " + cd + "...")
		if err := archiver.Unarchive(cd+CDFReddCoinBS, cd); err != nil {
			return fmt.Errorf("unable to unarchive file: %v - %v", cd+CDFReddCoinBS, err)
		}
	default:
		err := errors.New("unable to determine ProjectType - DownloadBlockchain")
		return err
	}
	return nil
}

func FindProcess(key string) (int, string, error) {
	pname := ""
	pid := 0
	err := errors.New("not found")
	process, _ := ps.Processes()

	for i := range process {
		if process[i].Executable() == key {
			pid = process[i].Pid()
			pname = process[i].Executable()
			err = nil
			break
		}
	}
	return pid, pname, err
}

// GetAppFileName - Returns the name of the app binary file e.g. boxwallet or boxwallet.exe
func GetAppFileName() (string, error) {
	switch runtime.GOOS {
	case "arm":
		return CAppFilename, nil
	case "linux":
		return CAppFilename, nil
	case "windows":
		return CAppFilenameWin, nil
	default:
		err := errors.New("unable to determine runtime.GOOS")
		return "", err
	}

	return "", nil
}

// // DoPrivKeyFile - Handles the private key
// func DoPrivKeyFile() error {
// 	dbf, err := GetAppsBinFolder()
// 	if err != nil {
// 		return fmt.Errorf("Unable to GetAppsBinFolder: %v", err)
// 	}

// 	// User specified that they wanted to save their private key in a file.
// 	s := getWalletSeedDisplayWarning() + `

// Storing your private key in a file is risky.

// Please confirm that you understand the risks: `
// 	yn := getYesNoResp(s)
// 	if yn == "y" {
// 		fmt.Println("\nRequesting private seed...")
// 		s, err := runDCCommand(dbf+cDiviCliFile, cCommandDumpHDinfo, "Waiting for wallet to respond. This could take several minutes...", 30)
// 		// cmd := exec.Command(dbf+cDiviCliFile, cCommandDumpHDinfo)
// 		// out, err := cmd.CombinedOutput()
// 		if err != nil {
// 			return fmt.Errorf("Unable to run command: %v - %v", dbf+cDiviCliFile+cCommandDumpHDinfo, err)
// 		}

// 		// Now store the info in file
// 		err = WriteTextToFile(dbf+cWalletSeedFileGoDivi, s)
// 		if err != nil {
// 			return fmt.Errorf("error writing to file %s", err)
// 		}
// 		fmt.Println("Now please store the privte seed file somewhere safe. The file has been saved to: " + dbf + cWalletSeedFileGoDivi)
// 	}
// 	return nil
// }

// func doWalletAdressDisplay() error {
// 	err := gwc.StartCoinDaemon(false)
// 	if err != nil {
// 		return fmt.Errorf("Unable to StartCoinDaemon: %v ", err)
// 	}

// 	dbf, err := gwc.GetAppsBinFolder()
// 	if err != nil {
// 		return fmt.Errorf("Unable to GetAppsBinFolder: %v", err)
// 	}
// 	// Display wallet public address

// 	fmt.Println("\nRequesting wallet address...")
// 	s, err := RunDCCommandWithValue(dbf+cDiviCliFile, cCommandDisplayWalletAddress, `""`, "Waiting for wallet to respond. This could take several minutes...", 30)
// 	if err != nil {
// 		return fmt.Errorf("Unable to run command: %v - %v", dbf+cDiviCliFile+cCommandDisplayWalletAddress, err)
// 	}

// 	fmt.Println("\nWallet address received...")
// 	fmt.Println("")
// 	println(s)

// 	return nil
// }

//func getBlockchainInfo() (blockChainInfo, error) {
//	bci := blockChainInfo{}
//	dbf, _ := gwc.GetAppsBinFolder(gwc.APPTServer)
//
//	cmdBCInfo := exec.Command(dbf+gwc.CDiviCliFile, cCommandGetBCInfo)
//	out, _ := cmdBCInfo.CombinedOutput()
//	err := json.Unmarshal([]byte(out), &bci)
//	if err != nil {
//		return bci, err
//	}
//	return bci, nil
//}

// GetCoinDaemonFilename - Return the coin daemon file name e.g. divid
func GetCoinDaemonFilename(at APPType, pt ProjectType) (string, error) {
	//var pt ProjectType
	switch at {
	case APPTCLI:
		conf, err := GetConfigStruct("", false)
		if err != nil {
			return "", err
		}
		pt = conf.ProjectType
	default:
		err := errors.New("unable to determine AppType")
		return "", err
	}

	switch pt {
	case PTBitcoinPlus:
		return CDFileBitcoinPlus, nil
	case PTDenarius:
		return CDFileDenarius, nil
	case PTDeVault:
		return CDFileDeVault, nil
	case PTDigiByte:
		return CDFileDigiByte, nil
	case PTDivi:
		return CDiviDFile, nil
	case PTFeathercoin:
		return CDFileFeathercoin, nil
	case PTGroestlcoin:
		return CDFileGroestlcoin, nil
	case PTPhore:
		return CPhoreDFile, nil
	case PTPIVX:
		return CPIVXDFile, nil
	case PTRapids:
		return CRapidsDFile, nil
	case PTReddCoin:
		return CReddCoinDFile, nil
	case PTScala:
		return CScalaDFile, nil
	case PTSyscoin:
		return CSyscoinDFile, nil
	case PTTrezarcoin:
		return CTrezarcoinDFile, nil
	case PTVertcoin:
		return CVertcoinDFile, nil
	default:
		err := errors.New("unable to determine ProjectType")
		return "", err
	}

	return "", nil
}

// GetCoinName - Returns the name of the coin e.g. Divi
func GetCoinName(at APPType) (string, error) {
	var pt ProjectType
	switch at {
	case APPTCLI:
		conf, err := GetConfigStruct("", false)
		if err != nil {
			return "", err
		}
		pt = conf.ProjectType
	default:
		err := errors.New("unable to determine AppType")
		return "", err
	}

	switch pt {
	case PTBitcoinPlus:
		return CCoinNameBitcoinPlus, nil
	case PTDenarius:
		return CCoinNameDenarius, nil
	case PTDeVault:
		return CCoinNameDeVault, nil
	case PTDigiByte:
		return CCoinNameDigiByte, nil
	case PTDivi:
		return CCoinNameDivi, nil
	case PTFeathercoin:
		return CCoinNameFeathercoin, nil
	case PTGroestlcoin:
		return CCoinNameGroestlcoin, nil
	case PTPhore:
		return CCoinNamePhore, nil
	case PTPIVX:
		return CCoinNamePIVX, nil
	case PTRapids:
		return CCoinNameRapids, nil
	case PTReddCoin:
		return CCoinNameReddCoin, nil
	case PTScala:
		return CCoinNameScala, nil
	case PTSyscoin:
		return CCoinNameSyscoin, nil
	case PTTrezarcoin:
		return CCoinNameTrezarcoin, nil
	case PTVertcoin:
		return CCoinNameVertcoin, nil
	default:
		err := errors.New("unable to determine ProjectType")
		return "", err
	}

	return "", nil
}

// GetCoinHomeFolder - Returns the home folder for the coin e.g. .divi
func GetCoinHomeFolder(at APPType, pt ProjectType) (string, error) {
	//var pt ProjectType
	switch at {
	case APPTCLI:
		//conf, err := GetConfigStruct("", false)
		//if err != nil {
		//	return "", err
		//}
	//	pt = conf.ProjectType
	default:
		err := errors.New("unable to determine AppType")
		return "", err
	}

	var s string
	u, err := user.Current()
	if err != nil {
		return "", err
	}
	hd := u.HomeDir
	if runtime.GOOS == "windows" {
		// add the "appdata\roaming" part.
		switch pt {
		case PTBitcoinPlus:
			s = AddTrailingSlash(hd) + "appdata\\roaming\\" + AddTrailingSlash(cHomeDirWinBitcoinPlus)
		case PTDenarius:
			s = AddTrailingSlash(hd) + "appdata\\roaming\\" + AddTrailingSlash(cHomeDirWinDenarius)
		case PTDeVault:
			s = AddTrailingSlash(hd) + "appdata\\roaming\\" + AddTrailingSlash(cHomeDirWinDeVault)
		case PTDigiByte:
			s = AddTrailingSlash(hd) + "appdata\\roaming\\" + AddTrailingSlash(cHomeDirWinDigiByte)
		case PTDivi:
			s = AddTrailingSlash(hd) + "appdata\\roaming\\" + AddTrailingSlash(cHomeDirWinDivi)
		case PTFeathercoin:
			s = AddTrailingSlash(hd) + "appdata\\roaming\\" + AddTrailingSlash(cHomeDirWinFeathercoin)
		case PTGroestlcoin:
			s = AddTrailingSlash(hd) + "appdata\\roaming\\" + AddTrailingSlash(cHomeDirWinGroestlcoin)
		case PTPhore:
			s = AddTrailingSlash(hd) + "appdata\\roaming\\" + AddTrailingSlash(cPhoreHomeDirWin)
		case PTPIVX:
			s = AddTrailingSlash(hd) + "appdata\\roaming\\" + AddTrailingSlash(cPIVXHomeDirWin)
		case PTRapids:
			s = AddTrailingSlash(hd) + "appdata\\roaming\\" + AddTrailingSlash(cRapidsHomeDirWin)
		case PTReddCoin:
			s = AddTrailingSlash(hd) + "appdata\\roaming\\" + AddTrailingSlash(cReddCoinHomeDirWin)
		case PTScala:
			s = AddTrailingSlash(hd) + "appdata\\roaming\\" + AddTrailingSlash(cScalaHomeDirWin)
		case PTSyscoin:
			s = AddTrailingSlash(hd) + "appdata\\roaming\\" + AddTrailingSlash(cSyscoinHomeDirWin)
		case PTTrezarcoin:
			s = AddTrailingSlash(hd) + "appdata\\roaming\\" + AddTrailingSlash(cTrezarcoinHomeDirWin)
		case PTVertcoin:
			s = AddTrailingSlash(hd) + "appdata\\roaming\\" + AddTrailingSlash(cVertcoinHomeDirWin)
		default:
			err = errors.New("unable to determine ProjectType")

		}
	} else {
		switch pt {
		case PTBitcoinPlus:
			s = AddTrailingSlash(hd) + AddTrailingSlash(cHomeDirLinBitcoinPlus)
		case PTDenarius:
			s = AddTrailingSlash(hd) + AddTrailingSlash(cHomeDirLinDenarius)
		case PTDeVault:
			s = AddTrailingSlash(hd) + AddTrailingSlash(cHomeDirLinDeVault)
		case PTDigiByte:
			s = AddTrailingSlash(hd) + AddTrailingSlash(cHomeDirLinDigiByte)
		case PTDivi:
			s = AddTrailingSlash(hd) + AddTrailingSlash(cHomeDirDivi)
		case PTFeathercoin:
			s = AddTrailingSlash(hd) + AddTrailingSlash(cHomeDirFeathercoin)
		case PTGroestlcoin:
			s = AddTrailingSlash(hd) + AddTrailingSlash(cHomeDirGroestlcoin)
		case PTPhore:
			s = AddTrailingSlash(hd) + AddTrailingSlash(cPhoreHomeDir)
		case PTPIVX:
			s = AddTrailingSlash(hd) + AddTrailingSlash(cPIVXHomeDir)
		case PTRapids:
			s = AddTrailingSlash(hd) + AddTrailingSlash(cRapidsHomeDir)
		case PTReddCoin:
			s = AddTrailingSlash(hd) + AddTrailingSlash(cReddCoinHomeDir)
		case PTScala:
			s = AddTrailingSlash(hd) + AddTrailingSlash(cScalaHomeDir)
		case PTSyscoin:
			s = AddTrailingSlash(hd) + AddTrailingSlash(cSyscoinHomeDir)
		case PTTrezarcoin:
			s = AddTrailingSlash(hd) + AddTrailingSlash(cTrezarcoinHomeDir)
		case PTVertcoin:
			s = AddTrailingSlash(hd) + AddTrailingSlash(cVertcoinHomeDir)
		default:
			err = errors.New("unable to determine ProjectType")

		}
	}
	return s, nil
}

func GetAppWorkingFolder() (string, error) {
	var s string
	u, err := user.Current()
	if err != nil {
		return "", err
	}
	hd := u.HomeDir
	if runtime.GOOS == "windows" {
		// add the "appdata\roaming" part.
		s = addTrailingSlash(hd) + "appdata\\roaming\\" + addTrailingSlash(cAppWorkingDirWin)
	} else {
		s = AddTrailingSlash(hd) + AddTrailingSlash(cAppWorkingDirLin)
	}
	return s, nil
}

func GetPIVXSaplingDir() (string, error) {
	var s string
	u, err := user.Current()
	if err != nil {
		return "", err
	}
	hd := u.HomeDir
	if runtime.GOOS == "windows" {
		// add the "appdata\roaming" part.
		s = addTrailingSlash(hd) + "appdata\\roaming\\" + addTrailingSlash(CPIVXSaplingDirWindows)
	} else {
		s = AddTrailingSlash(hd) + AddTrailingSlash(CPIVXSaplingDirLinux)
	}
	return s, nil
}

// func GetWalletInfo(dispProgress bool) (walletInfoStruct, walletResponseType, error) {
// 	wi := walletInfoStruct{}

// 	// Start the DiviD server if required...
// 	err := StartCoinDaemon(false)
// 	if err != nil {
// 		return wi, wrtUnknown, fmt.Errorf("Unable to RunDiviD: %v ", err)
// 	}

// 	dbf, err := gwc.GetAppsBinFolder(gwc.APPTServer)
// 	if err != nil {
// 		return wi, wrtUnknown, fmt.Errorf("Unable to GetAppsBinFolder: %v ", err)
// 	}

// 	for i := 0; i <= 4; i++ {
// 		cmd := exec.Command(dbf+gwc.CDiviCliFile, cCommandGetWalletInfo)
// 		var stdout bytes.Buffer
// 		cmd.Stdout = &stdout
// 		cmd.Run()
// 		if err != nil {
// 			return wi, wrtUnknown, err
// 		}

// 		outStr := string(stdout.Bytes())
// 		wr := getWalletResponse(outStr)

// 		// cmd := exec.Command(dbf+gwc.CDiviCliFile, cCommandGetWalletInfo)
// 		// out, err := cmd.CombinedOutput()
// 		// sOut := string(out)
// 		//wr := getWalletResponse(sOut)
// 		if wr == wrtAllOK {
// 			errUM := json.Unmarshal([]byte(outStr), &wi)
// 			if errUM == nil {
// 				return wi, wrtAllOK, err
// 			}
// 		}

// 		time.Sleep(1 * time.Second)
// 	}
// 	return wi, wrtUnknown, errors.New("Unable to retrieve wallet info")
// }

func GetPasswordToEncryptWallet() string {
	for i := 0; i <= 2; i++ {
		epw1 := ""
		prompt := &survey.Password{
			Message: "Please enter a password to encrypt your wallet",
		}
		_ = survey.AskOne(prompt, &epw1)

		epw2 := ""
		prompt2 := &survey.Password{
			Message: "Now please re-enter your password",
		}
		_ = survey.AskOne(prompt2, &epw2)
		if epw1 != epw2 {
			fmt.Print("\nThe passwords don't match, please try again...\n")
		} else {
			return epw1
		}
	}
	return ""
}

func GetTipAddress(pt ProjectType) string {
	switch pt {
	case PTBitcoinPlus:
		return "BButzXzJj9KqhfEbF7rLxqN9jC7mT4MX15"
	case PTDenarius:
		return "DNxQWmq3JocvccZNcEGPpztB87GMEd3XVi"
	case PTDeVault:
		return "devault:qp7w4pnm774c0uwch8ty6tj7sw86hze9ps4sqrwcue"
	case PTDigiByte:
		return "dgb1qdw7qhh5crt3rhfau909pmc9r0esnnzqf48un6g"
	case PTDivi:
		return "DGvhjUXznuDyALk9zX4Y3ko4QQTmRhF7jZ"
	case PTFeathercoin:
		return "6yWAnPUcgWGXnXAM9u4faDVmfJwxKphcLf"
	case PTGroestlcoin:
		return "3HBqpZ1JH125FmW52GYjoBpNEAwyxjL9t9"
	case PTPhore:
		return "PKFcy7UTEWegnAq7Wci8Aj76bQyHMottF8"
	case PTPIVX:
		return "DFHmj4dExVC24eWoRKmQJDx57r4svGVs3J"
	case PTRapids:
		return "RvxCvM2VWVKq2iSLNoAmzdqH4eF9bhvn6k"
	case PTReddCoin:
		return "RtH6nZvmnstUsy5w5cmdwTrarbTPm6zyrC"
	case PTScala:
		return "Svkhh1KJ7qSPEtoAzAuriLUzVSseezcs2GS21bAL5rWEYD2iBykLvHUaMaQEcrF1pPfTkfEbWGsXz4zfXJWmQvat2Q2EHhS1e"
	case PTSyscoin:
		return "sys1qkj3tfnpndluj85k5vmfzccxfsl6nt4kn6slxey"
	case PTTrezarcoin:
		return "TnkHScr6iTcfK11GDPFjNgJ7V3GZtHEy9V"
	case PTVertcoin:
		return "vtc1q72j7fre83q8a7feppj28qkzfdt5vkcjr7xd74p"
	default:
		return "DGvhjUXznuDyALk9zX4Y3ko4QQTmRhF7jZ"
	}
}

func GetTipInfo(pt ProjectType) string {

	// Get tip address part.
	var s string
	switch pt {
	case PTBitcoinPlus:
		s = CCoinAbbrevBitcoinPlus + ": " + GetTipAddress(PTBitcoinPlus)
	case PTDenarius:
		s = CCoinAbbrevDenarius + ": " + GetTipAddress(PTDenarius)
	case PTDeVault:
		s = CCoinAbbrevDeVault + ": " + GetTipAddress(PTDeVault)
	case PTDigiByte:
		s = CCoinAbbrevDigiByte + ": " + GetTipAddress(PTDigiByte)
	case PTDivi:
		s = CCoinAbbrevDivi + ": " + GetTipAddress(PTDivi)
	case PTFeathercoin:
		s = CCoinAbbrevFeathercoin + ": " + GetTipAddress(PTFeathercoin)
	case PTGroestlcoin:
		s = CCoinAbbrevGroestlcoin + ": " + GetTipAddress(PTGroestlcoin)
	case PTPhore:
		s = CCoinAbbrevPhore + ": " + GetTipAddress(PTPhore)
	case PTPIVX:
		s = CCoinAbbrevPIVX + ": " + GetTipAddress(PTPIVX)
	case PTRapids:
		s = CCoinAbbrevRapids + ": " + GetTipAddress(PTRapids)
	case PTReddCoin:
		s = CCoinAbbrevReddCoin + ": " + GetTipAddress(PTReddCoin)
	case PTScala:
		s = CCoinAbbrevScala + ": " + GetTipAddress(PTScala)
	case PTSyscoin:
		s = CCoinAbbrevSyscoin + ": " + GetTipAddress(PTSyscoin)
	case PTTrezarcoin:
		s = CCoinAbbrevTrezarcoin + ": " + GetTipAddress(PTTrezarcoin)
	case PTVertcoin:
		s = CCoinAbbrevVertcoin + ": " + GetTipAddress(PTVertcoin)
	default:
		s = CCoinAbbrevDivi + ": " + GetTipAddress(PTDivi)
	}
	sCoinName, err := GetCoinName(APPTCLI)
	if err != nil {
		log.Fatal("Unable to GetCoinName " + err.Error())
	}

	sInfo := "Thank you for using " + CAppName + " to run your " + sCoinName + " wallet/node." + "\n\n" +
		CAppName + " is FREE to use, however, all donations are most welcome at the " + sCoinName + " address below:" + "\n\n" +
		s

	return sInfo
}

func GetWalletEncryptionPassword() string {
	pw := ""
	prompt := &survey.Password{
		Message: "Please enter your wallet password",
	}
	survey.AskOne(prompt, &pw)
	return pw
}

func GetWalletEncryptionResp() bool {
	ans := false
	prompt := &survey.Confirm{
		Message: `Your wallet is currently UNENCRYPTED!

It is *highly* recommended that you encrypt your wallet before proceeding any further.

Encrypt it now?:`,
	}
	survey.AskOne(prompt, &ans)
	return ans
}

func GetWalletEncryptionStatus() (WEType, error) {
	conf, err := GetConfigStruct("", false)
	if err != nil {
		return WETUnknown, err
	}
	pt := conf.ProjectType
	switch pt {
	case PTBitcoinPlus:
		wi, err := GetWalletInfoXBC(&conf)
		if err != nil {
			return WETUnknown, fmt.Errorf("unable to GetWalletInfoDigiByte %v", err)
		}
		wet := GetWalletSecurityStateXBC(&wi)
		return wet, nil
	case PTDenarius:
		// Denarius doesn't have WalletInfo, but you can get the same info from GetInfo
		gi, err := GetInfoDenarius(&conf)
		if err != nil {
			return WETUnknown, fmt.Errorf("unable to GetWalletInfoDenarius %v", err)
		}
		wet := GetWalletSecurityStateDenarius(&gi)
		return wet, nil
	case PTDeVault:
		wi, err := GetWalletInfoDVT(&conf)
		if err != nil {
			return WETUnknown, fmt.Errorf("unable to GetWalletInfoDVT %v", err)
		}
		wet := GetWalletSecurityStateDVT(&wi)
		return wet, nil
	case PTDigiByte:
		wi, err := GetWalletInfoDGB(&conf)
		if err != nil {
			return WETUnknown, fmt.Errorf("unable to GetWalletInfoDigiByte %v", err)
		}
		wet := GetWalletSecurityStateDGB(&wi)
		return wet, nil
	case PTDivi:
		wi, err := GetWalletInfoDivi(&conf)
		if err != nil {
			return WETUnknown, fmt.Errorf("unable to GetWalletInfoDivi %v", err)
		}
		wet := GetWalletSecurityStateDivi(&wi)
		return wet, nil
	case PTFeathercoin:
		wi, err := GetWalletInfoFeathercoin(&conf)
		if err != nil {
			return WETUnknown, fmt.Errorf("unable to GetWalletInfoFeathercoin %v", err)
		}
		wet := GetWalletSecurityStateFeathercoin(&wi)
		return wet, nil
	case PTGroestlcoin:
		wi, err := GetWalletInfoGRS(&conf)
		if err != nil {
			return WETUnknown, fmt.Errorf("unable to GteWalletInfoGRS %v", err)
		}
		wet := GetWalletSecurityStateGRS(&wi)
		return wet, nil
	case PTPhore:
		wi, err := GetWalletInfoPhore(&conf)
		if err != nil {
			return WETUnknown, fmt.Errorf("unable to GetWalletInfoPhore %v", err)
		}
		wet := GetWalletSecurityStatePhore(&wi)
		return wet, nil
	case PTPIVX:
		wi, err := GetWalletInfoPIVX(&conf)
		if err != nil {
			return WETUnknown, fmt.Errorf("unable to GetWalletInfoPIVX %v", err)
		}
		wet := GetWalletSecurityStatePIVX(&wi)
		return wet, nil
	case PTRapids:
		wi, err := GetWalletInfoRapids(&conf)
		if err != nil {
			return WETUnknown, fmt.Errorf("unable to GetWalletInfoRapids %v", err)
		}
		wet := GetWalletSecurityStateRapids(&wi)
		return wet, nil
	case PTReddCoin:
		wi, err := GetWalletInfoRDD(&conf)
		if err != nil {
			return WETUnknown, fmt.Errorf("unable to GetWalletInfoRDD %v", err)
		}
		wet := GetWalletSecurityStateRDD(&wi)
		return wet, nil
	case PTTrezarcoin:
		wi, err := GetWalletInfoTrezarcoin(&conf)
		if err != nil {
			return WETUnknown, fmt.Errorf("unable to GetWalletInfoTrezarcoin %v", err)
		}
		wet := GetWalletSecurityStateTrezarcoin(&wi)
		return wet, nil
	case PTVertcoin:
		wi, err := GetWalletInfoVTC(&conf)
		if err != nil {
			return WETUnknown, fmt.Errorf("unable to GetWalletInfoVertcoin %v", err)
		}
		wet := GetWalletSecurityStateVTC(&wi)
		return wet, nil
	default:
		err = errors.New("unable to determine ProjectType")
	}
	return WETUnknown, nil
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

// IsCoinDaemonRunning - Works out whether the coin Daemon is running e.g. divid
func IsCoinDaemonRunning(ct ProjectType) (bool, int, error) {
	var pid int

	//bwconf, err := GetConfigStruct("", false)
	//if err != nil {
	//	return false, pid, err
	//}
	//switch bwconf.ProjectType {

	var err error
	switch ct {
	case PTBitcoinPlus:
		if runtime.GOOS == "windows" {
			pid, _, err = FindProcess(CDFileWinBitcoinPlus)
		} else {
			pid, _, err = FindProcess(CDFileBitcoinPlus)
		}
	case PTDenarius:
		if runtime.GOOS == "windows" {
			pid, _, err = FindProcess(CDFileWinDenarius)
		} else {
			pid, _, err = FindProcess(CDMemDenarius)
		}
	case PTDeVault:
		if runtime.GOOS == "windows" {
			pid, _, err = FindProcess(CDFileWinDeVault)
		} else {
			pid, _, err = FindProcess(CDFileDeVault)
		}
	case PTDigiByte:
		if runtime.GOOS == "windows" {
			pid, _, err = FindProcess(CDFileWinDigiByte)
		} else {
			pid, _, err = FindProcess(CDFileDigiByte)
		}
	case PTDivi:
		if runtime.GOOS == "windows" {
			pid, _, err = FindProcess(CDiviDFileWin)
		} else {
			pid, _, err = FindProcess(CDiviDFile)
		}
	case PTFeathercoin:
		if runtime.GOOS == "windows" {
			pid, _, err = FindProcess(CDFileWinFeathercoin)
		} else {
			pid, _, err = FindProcess(CDFileFeathercoin)
		}
	case PTGroestlcoin:
		if runtime.GOOS == "windows" {
			pid, _, err = FindProcess(CDFileWinGroestlcoin)
		} else {
			pid, _, err = FindProcess(CDFileGroestlcoin)
		}
	case PTPhore:
		if runtime.GOOS == "windows" {
			pid, _, err = FindProcess(CPhoreDFileWin)
		} else {
			pid, _, err = FindProcess(CPhoreDFile)
		}
	case PTPIVX:
		if runtime.GOOS == "windows" {
			pid, _, err = FindProcess(CPIVXDFileWin)
		} else {
			pid, _, err = FindProcess(CPIVXDFile)
		}
	case PTRapids:
		if runtime.GOOS == "windows" {
			pid, _, err = FindProcess(CRapidsDFileWin)
		} else {
			pid, _, err = FindProcess(CRapidsDFile)
		}
	case PTReddCoin:
		if runtime.GOOS == "windows" {
			pid, _, err = FindProcess(CReddCoinDFileWin)
		} else {
			pid, _, err = FindProcess(CReddCoinDFile)
		}
	case PTScala:
		if runtime.GOOS == "windows" {
			pid, _, err = FindProcess(CScalaDFileWin)
		} else {
			pid, _, err = FindProcess(CScalaDFile)
		}
	case PTSyscoin:
		if runtime.GOOS == "windows" {
			pid, _, err = FindProcess(CSyscoinDFileWin)
		} else {
			pid, _, err = FindProcess(CSyscoinDFile)
		}
	case PTTrezarcoin:
		if runtime.GOOS == "windows" {
			pid, _, err = FindProcess(CTrezarcoinDFileWin)
		} else {
			pid, _, err = FindProcess(CTrezarcoinDFile)
		}
	case PTVertcoin:
		if runtime.GOOS == "windows" {
			pid, _, err = FindProcess(CVertcoinDFileWin)
		} else {
			pid, _, err = FindProcess(CVertcoinDFile)
		}
	default:
		err = errors.New("unable to determine ProjectType")
	}

	if err == nil {
		return true, pid, nil //fmt.Printf ("Pid:%d, Pname:%s\n", pid, s)
	}
	if err.Error() == "not found" {
		return false, pid, nil //fmt.Printf ("Pid:%d, Pname:%s\n", pid, s)
	} else {
		return false, 0, err
	}
}

// PopulateDaemonConfFile - Populates the divi.conf file
func PopulateDaemonConfFile() (rpcuser, rpcpassword string, err error) {

	bFileHasBeenBU := false
	bwconf, err := GetConfigStruct("", false)
	if err != nil {
		return "", "", fmt.Errorf("unable to GetConfigStruct - %v", err)
	}

	// Create the coins home folder if required...
	chd, _ := GetCoinHomeFolder(APPTCLI, bwconf.ProjectType)
	if err := os.MkdirAll(chd, os.ModePerm); err != nil {
		return "", "", fmt.Errorf("unable to make directory - %v", err)
	}

	// Create user and password variables
	var rpcu string
	var rpcpw string

	switch bwconf.ProjectType {
	case PTBitcoinPlus:
		fmt.Println("Populating " + cConfFileBitcoinPlus + " for initial setup...")

		// Add rpcuser info if required, or retrieve the existing one
		bNeedToWriteStr := true
		if FileExists(chd + cConfFileBitcoinPlus) {
			bStrFound, err := StringExistsInFile(cRPCUserStr+"=", chd+cConfFileBitcoinPlus)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileBitcoinPlus, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
				rpcu, err = GetStringAfterStrFromFile(cRPCUserStr+"=", chd+cConfFileBitcoinPlus)
				if err != nil {
					return "", "", fmt.Errorf("unable to search for text in file - %v", err)
				}
			}
		} else {
			// Set this to true, because the file has just been freshly created and we don't want to back it up
			bFileHasBeenBU = true
		}
		if bNeedToWriteStr {
			rpcu = CRPCUserBitcoinPlus
			if err := WriteTextToFile(chd+cConfFileBitcoinPlus, cRPCUserStr+"="+rpcu); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcpassword info if required, or retrieve the existing one
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileBitcoinPlus) {
			bStrFound, err := StringExistsInFile(cRPCPasswordStr+"=", chd+cConfFileBitcoinPlus)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileBitcoinPlus, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
				rpcpw, err = GetStringAfterStrFromFile(cRPCPasswordStr+"=", chd+cConfFileBitcoinPlus)
				if err != nil {
					return "", "", fmt.Errorf("unable to search for text in file - %v", err)
				}
			}
		}
		if bNeedToWriteStr {
			rpcpw = rand.String(20)
			if err := WriteTextToFile(chd+cConfFileBitcoinPlus, cRPCPasswordStr+"="+rpcpw); err != nil {
				log.Fatal(err)
			}
			if err := WriteTextToFile(chd+cConfFileBitcoinPlus, ""); err != nil {
				log.Fatal(err)
			}
		}

		// Add daemon=1 info if required
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileBitcoinPlus) {
			bStrFound, err := StringExistsInFile("daemon=1", chd+cConfFileBitcoinPlus)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileBitcoinPlus, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cConfFileBitcoinPlus, "daemon=1"); err != nil {
				log.Fatal(err)
			}
			if err := WriteTextToFile(chd+cConfFileBitcoinPlus, ""); err != nil {
				log.Fatal(err)
			}
		}

		// Add server=1 info if required
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileBitcoinPlus) {
			bStrFound, err := StringExistsInFile("server=1", chd+cConfFileBitcoinPlus)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileBitcoinPlus, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cConfFileBitcoinPlus, "server=1"); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcallowip= info if required
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileBitcoinPlus) {
			bStrFound, err := StringExistsInFile("rpcallowip=", chd+cConfFileBitcoinPlus)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileBitcoinPlus, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cConfFileBitcoinPlus, "rpcallowip=192.168.1.0/255.255.255.0"); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcport= info if required
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileBitcoinPlus) {
			bStrFound, err := StringExistsInFile("rpcport=", chd+cConfFileBitcoinPlus)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileBitcoinPlus, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cConfFileBitcoinPlus, "rpcport="+CRPCPortBitcoinPlus); err != nil {
				log.Fatal(err)
			}
		}

		return rpcu, rpcpw, nil
	case PTDenarius:
		fmt.Println("Populating " + cConfFileDenarius + " for initial setup...")

		// Add rpcuser info if required, or retrieve the existing one
		bNeedToWriteStr := true
		if FileExists(chd + cConfFileDenarius) {
			bStrFound, err := StringExistsInFile(cRPCUserStr+"=", chd+cConfFileDenarius)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileDenarius, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
				rpcu, err = GetStringAfterStrFromFile(cRPCUserStr+"=", chd+cConfFileDenarius)
				if err != nil {
					return "", "", fmt.Errorf("unable to search for text in file - %v", err)
				}
			}
		} else {
			// Set this to true, because the file has just been freshly created and we don't want to back it up
			bFileHasBeenBU = true
		}
		if bNeedToWriteStr {
			rpcu = cRPCUserDenarius
			if err := WriteTextToFile(chd+cConfFileDenarius, cRPCUserStr+"="+rpcu); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcpassword info if required, or retrieve the existing one.
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileDenarius) {
			bStrFound, err := StringExistsInFile(cRPCPasswordStr+"=", chd+cConfFileDenarius)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileDenarius, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
				rpcpw, err = GetStringAfterStrFromFile(cRPCPasswordStr+"=", chd+cConfFileDenarius)
				if err != nil {
					return "", "", fmt.Errorf("unable to search for text in file - %v", err)
				}
			}
		}
		if bNeedToWriteStr {
			rpcpw = rand.String(20)
			if err := WriteTextToFile(chd+cConfFileDenarius, cRPCPasswordStr+"="+rpcpw); err != nil {
				log.Fatal(err)
			}
			if err := WriteTextToFile(chd+cConfFileDenarius, ""); err != nil {
				log.Fatal(err)
			}
		}

		// Add daemon=1 info if required
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileDenarius) {
			bStrFound, err := StringExistsInFile("daemon=1", chd+cConfFileDenarius)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileDenarius, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cConfFileDenarius, "daemon=1"); err != nil {
				log.Fatal(err)
			}
			if err := WriteTextToFile(chd+cConfFileDenarius, ""); err != nil {
				log.Fatal(err)
			}
		}

		// Add server=1 info if required
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileDenarius) {
			bStrFound, err := StringExistsInFile("server=1", chd+cConfFileDenarius)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileDenarius, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cConfFileDenarius, "server=1"); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcallowip= info if required
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileDenarius) {
			bStrFound, err := StringExistsInFile("rpcallowip=", chd+cConfFileDenarius)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileDenarius, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cConfFileDenarius, "rpcallowip=192.168.1.0/255.255.255.0"); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcport= info if required
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileDenarius) {
			bStrFound, err := StringExistsInFile("rpcport=", chd+cConfFileDenarius)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileDenarius, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cConfFileDenarius, "rpcport="+CRPCPortDenarius); err != nil {
				log.Fatal(err)
			}
		}

		return rpcu, rpcpw, nil
	case PTDeVault:
		fmt.Println("Populating " + cConfFileDeVault + " for initial setup...")

		// Add rpcuser info if required, or retrieve the existing one
		bNeedToWriteStr := true
		if FileExists(chd + cConfFileDeVault) {
			bStrFound, err := StringExistsInFile(cRPCUserStr+"=", chd+cConfFileDeVault)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileDeVault, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
				rpcu, err = GetStringAfterStrFromFile(cRPCUserStr+"=", chd+cConfFileDeVault)
				if err != nil {
					return "", "", fmt.Errorf("unable to search for text in file - %v", err)
				}
			}
		} else {
			// Set this to true, because the file has just been freshly created and we don't want to back it up
			bFileHasBeenBU = true
		}
		if bNeedToWriteStr {
			rpcu = cRPCUserDeVault
			if err := WriteTextToFile(chd+cConfFileDeVault, cRPCUserStr+"="+rpcu); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcpassword info if required, or retrieve the existing one
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileDeVault) {
			bStrFound, err := StringExistsInFile(cRPCPasswordStr+"=", chd+cConfFileDeVault)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileDeVault, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
				rpcpw, err = GetStringAfterStrFromFile(cRPCPasswordStr+"=", chd+cConfFileDeVault)
				if err != nil {
					return "", "", fmt.Errorf("unable to search for text in file - %v", err)
				}
			}
		}
		if bNeedToWriteStr {
			rpcpw = rand.String(20)
			if err := WriteTextToFile(chd+cConfFileDeVault, cRPCPasswordStr+"="+rpcpw); err != nil {
				log.Fatal(err)
			}
			if err := WriteTextToFile(chd+cConfFileDeVault, ""); err != nil {
				log.Fatal(err)
			}
		}

		// Add daemon=1 info if required
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileDeVault) {
			bStrFound, err := StringExistsInFile("daemon=1", chd+cConfFileDeVault)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileDeVault, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cConfFileDeVault, "daemon=1"); err != nil {
				log.Fatal(err)
			}
			if err := WriteTextToFile(chd+cConfFileDeVault, ""); err != nil {
				log.Fatal(err)
			}
		}

		// Add server=1 info if required
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileDeVault) {
			bStrFound, err := StringExistsInFile("server=1", chd+cConfFileDeVault)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileDeVault, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cConfFileDeVault, "server=1"); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcallowip= info if required
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileDeVault) {
			bStrFound, err := StringExistsInFile("rpcallowip=", chd+cConfFileDeVault)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileDeVault, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cConfFileDeVault, "rpcallowip=192.168.1.0/255.255.255.0"); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcport= info if required
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileDeVault) {
			bStrFound, err := StringExistsInFile("rpcport=", chd+cConfFileDeVault)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileDeVault, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cConfFileDeVault, "rpcport="+CRPCPortDeVault); err != nil {
				log.Fatal(err)
			}
		}

		return rpcu, rpcpw, nil
	case PTDigiByte:
		fmt.Println("Populating " + CConfFileDigiByte + " for initial setup...")

		// Add rpcuser info if required, or retrieve the existing one
		bNeedToWriteStr := true
		if FileExists(chd + CConfFileDigiByte) {
			bStrFound, err := StringExistsInFile(cRPCUserStr+"=", chd+CConfFileDigiByte)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CConfFileDigiByte, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
				rpcu, err = GetStringAfterStrFromFile(cRPCUserStr+"=", chd+CConfFileDigiByte)
				if err != nil {
					return "", "", fmt.Errorf("unable to search for text in file - %v", err)
				}
			}
		} else {
			// Set this to true, because the file has just been freshly created and we don't want to back it up
			bFileHasBeenBU = true
		}
		if bNeedToWriteStr {
			rpcu = cRPCUserDigiByte
			if err := WriteTextToFile(chd+CConfFileDigiByte, cRPCUserStr+"="+rpcu); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcpassword info if required, or retrieve the existing one
		bNeedToWriteStr = true
		if FileExists(chd + CConfFileDigiByte) {
			bStrFound, err := StringExistsInFile(cRPCPasswordStr+"=", chd+CConfFileDigiByte)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CConfFileDigiByte, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
				rpcpw, err = GetStringAfterStrFromFile(cRPCPasswordStr+"=", chd+CConfFileDigiByte)
				if err != nil {
					return "", "", fmt.Errorf("unable to search for text in file - %v", err)
				}
			}
		}
		if bNeedToWriteStr {
			rpcpw = rand.String(20)
			if err := WriteTextToFile(chd+CConfFileDigiByte, cRPCPasswordStr+"="+rpcpw); err != nil {
				log.Fatal(err)
			}
			if err := WriteTextToFile(chd+CConfFileDigiByte, ""); err != nil {
				log.Fatal(err)
			}
		}

		// Add daemon=1 info if required
		bNeedToWriteStr = true
		if FileExists(chd + CConfFileDigiByte) {
			bStrFound, err := StringExistsInFile("daemon=1", chd+CConfFileDigiByte)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CConfFileDigiByte, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+CConfFileDigiByte, "daemon=1"); err != nil {
				log.Fatal(err)
			}
			if err := WriteTextToFile(chd+CConfFileDigiByte, ""); err != nil {
				log.Fatal(err)
			}
		}

		// Add server=1 info if required
		bNeedToWriteStr = true
		if FileExists(chd + CConfFileDigiByte) {
			bStrFound, err := StringExistsInFile("server=1", chd+CConfFileDigiByte)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CConfFileDigiByte, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+CConfFileDigiByte, "server=1"); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcallowip= info if required
		bNeedToWriteStr = true
		if FileExists(chd + CConfFileDigiByte) {
			bStrFound, err := StringExistsInFile("rpcallowip=", chd+CConfFileDigiByte)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CConfFileDigiByte, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+CConfFileDigiByte, "rpcallowip=192.168.1.0/255.255.255.0"); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcport= info if required
		bNeedToWriteStr = true
		if FileExists(chd + CConfFileDigiByte) {
			bStrFound, err := StringExistsInFile("rpcport=", chd+CConfFileDigiByte)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CConfFileDigiByte, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+CConfFileDigiByte, "rpcport="+CRPCPortDigiByte); err != nil {
				log.Fatal(err)
			}
		}

		return rpcu, rpcpw, nil
	case PTDivi:
		fmt.Println("Populating " + cConfFileDivi + " for initial setup...")

		// Add rpcuser info if required, or retrieve the existing one
		bNeedToWriteStr := true
		if FileExists(chd + cConfFileDivi) {
			bStrFound, err := StringExistsInFile(cRPCUserStr+"=", chd+cConfFileDivi)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileDivi, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
				rpcu, err = GetStringAfterStrFromFile(cRPCUserStr+"=", chd+cConfFileDivi)
				if err != nil {
					return "", "", fmt.Errorf("unable to search for text in file - %v", err)
				}
			}
		} else {
			// Set this to true, because the file has just been freshly created and we don't want to back it up
			bFileHasBeenBU = true
		}
		if bNeedToWriteStr {
			rpcu = cDiviRPCUser
			if err := WriteTextToFile(chd+cConfFileDivi, cRPCUserStr+"="+rpcu); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcpassword info if required, or retrieve the existing one
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileDivi) {
			bStrFound, err := StringExistsInFile(cRPCPasswordStr+"=", chd+cConfFileDivi)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileDivi, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
				rpcpw, err = GetStringAfterStrFromFile(cRPCPasswordStr+"=", chd+cConfFileDivi)
				if err != nil {
					return "", "", fmt.Errorf("unable to search for text in file - %v", err)
				}
			}
		}
		if bNeedToWriteStr {
			rpcpw = rand.String(20)
			if err := WriteTextToFile(chd+cConfFileDivi, cRPCPasswordStr+"="+rpcpw); err != nil {
				log.Fatal(err)
			}
			if err := WriteTextToFile(chd+cConfFileDivi, ""); err != nil {
				log.Fatal(err)
			}
		}

		// Add daemon=1 info if required
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileDivi) {
			bStrFound, err := StringExistsInFile("daemon=1", chd+cConfFileDivi)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileDivi, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cConfFileDivi, "daemon=1"); err != nil {
				log.Fatal(err)
			}
			if err := WriteTextToFile(chd+cConfFileDivi, ""); err != nil {
				log.Fatal(err)
			}
		}

		// Add server=1 info if required
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileDivi) {
			bStrFound, err := StringExistsInFile("server=1", chd+cConfFileDivi)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileDivi, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cConfFileDivi, "server=1"); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcallowip= info if required
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileDivi) {
			bStrFound, err := StringExistsInFile("rpcallowip=", chd+cConfFileDivi)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileDivi, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cConfFileDivi, "rpcallowip=192.168.1.0/255.255.255.0"); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcport= info if required
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileDivi) {
			bStrFound, err := StringExistsInFile("rpcport=", chd+cConfFileDivi)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileDivi, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cConfFileDivi, "rpcport="+CDiviRPCPort); err != nil {
				log.Fatal(err)
			}
		}

		return rpcu, rpcpw, nil
	case PTFeathercoin:
		fmt.Println("Populating " + cConfFileFeathercoin + " for initial setup...")

		// Add rpcuser info if required, or retrieve the existing one
		bNeedToWriteStr := true
		if FileExists(chd + cConfFileFeathercoin) {
			bStrFound, err := StringExistsInFile(cRPCUserStr+"=", chd+cConfFileFeathercoin)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileFeathercoin, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
				rpcu, err = GetStringAfterStrFromFile(cRPCUserStr+"=", chd+cConfFileFeathercoin)
				if err != nil {
					return "", "", fmt.Errorf("unable to search for text in file - %v", err)
				}
			}
		} else {
			// Set this to true, because the file has just been freshly created and we don't want to back it up
			bFileHasBeenBU = true
		}
		if bNeedToWriteStr {
			rpcu = cRPCUserFeathercoin
			if err := WriteTextToFile(chd+cConfFileFeathercoin, cRPCUserStr+"="+rpcu); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcpassword info if required, or retrieve the existing one
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileFeathercoin) {
			bStrFound, err := StringExistsInFile(cRPCPasswordStr+"=", chd+cConfFileFeathercoin)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileFeathercoin, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
				rpcpw, err = GetStringAfterStrFromFile(cRPCPasswordStr+"=", chd+cConfFileFeathercoin)
				if err != nil {
					return "", "", fmt.Errorf("unable to search for text in file - %v", err)
				}
			}
		}
		if bNeedToWriteStr {
			rpcpw = rand.String(20)
			if err := WriteTextToFile(chd+cConfFileFeathercoin, cRPCPasswordStr+"="+rpcpw); err != nil {
				log.Fatal(err)
			}
			if err := WriteTextToFile(chd+cConfFileFeathercoin, ""); err != nil {
				log.Fatal(err)
			}
		}

		// Add daemon=1 info if required
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileFeathercoin) {
			bStrFound, err := StringExistsInFile("daemon=1", chd+cConfFileFeathercoin)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileFeathercoin, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cConfFileFeathercoin, "daemon=1"); err != nil {
				log.Fatal(err)
			}
			if err := WriteTextToFile(chd+cConfFileFeathercoin, ""); err != nil {
				log.Fatal(err)
			}
		}

		// Add server=1 info if required
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileFeathercoin) {
			bStrFound, err := StringExistsInFile("server=1", chd+cConfFileFeathercoin)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileFeathercoin, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cConfFileFeathercoin, "server=1"); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcallowip= info if required
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileFeathercoin) {
			bStrFound, err := StringExistsInFile("rpcallowip=", chd+cConfFileFeathercoin)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileFeathercoin, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cConfFileFeathercoin, "rpcallowip=192.168.1.0/255.255.255.0"); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcport= info if required
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileFeathercoin) {
			bStrFound, err := StringExistsInFile("rpcport=", chd+cConfFileFeathercoin)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileFeathercoin, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cConfFileFeathercoin, "rpcport="+CRPCPortFeathercoin); err != nil {
				log.Fatal(err)
			}
		}

		return rpcu, rpcpw, nil
	case PTGroestlcoin:
		fmt.Println("Populating " + cConfFileGroestlcoin + " for initial setup...")

		// Add rpcuser info if required, or retrieve the existing one
		bNeedToWriteStr := true
		if FileExists(chd + cConfFileGroestlcoin) {
			bStrFound, err := StringExistsInFile(cRPCUserStr+"=", chd+cConfFileGroestlcoin)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileGroestlcoin, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
				rpcu, err = GetStringAfterStrFromFile(cRPCUserStr+"=", chd+cConfFileGroestlcoin)
				if err != nil {
					return "", "", fmt.Errorf("unable to search for text in file - %v", err)
				}
			}
		} else {
			// Set this to true, because the file has just been freshly created and we don't want to back it up
			bFileHasBeenBU = true
		}
		if bNeedToWriteStr {
			rpcu = cRPCUserGroestlcoin
			if err := WriteTextToFile(chd+cConfFileGroestlcoin, cRPCUserStr+"="+rpcu); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcpassword info if required, or retrieve the existing one
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileGroestlcoin) {
			bStrFound, err := StringExistsInFile(cRPCPasswordStr+"=", chd+cConfFileGroestlcoin)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileGroestlcoin, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
				rpcpw, err = GetStringAfterStrFromFile(cRPCPasswordStr+"=", chd+cConfFileGroestlcoin)
				if err != nil {
					return "", "", fmt.Errorf("unable to search for text in file - %v", err)
				}
			}
		}
		if bNeedToWriteStr {
			rpcpw = rand.String(20)
			if err := WriteTextToFile(chd+cConfFileGroestlcoin, cRPCPasswordStr+"="+rpcpw); err != nil {
				log.Fatal(err)
			}
			if err := WriteTextToFile(chd+cConfFileGroestlcoin, ""); err != nil {
				log.Fatal(err)
			}
		}

		// Add daemon=1 info if required
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileGroestlcoin) {
			bStrFound, err := StringExistsInFile("daemon=1", chd+cConfFileGroestlcoin)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileGroestlcoin, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cConfFileGroestlcoin, "daemon=1"); err != nil {
				log.Fatal(err)
			}
			if err := WriteTextToFile(chd+cConfFileGroestlcoin, ""); err != nil {
				log.Fatal(err)
			}
		}

		// Add server=1 info if required
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileGroestlcoin) {
			bStrFound, err := StringExistsInFile("server=1", chd+cConfFileGroestlcoin)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileGroestlcoin, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cConfFileGroestlcoin, "server=1"); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcallowip= info if required
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileGroestlcoin) {
			bStrFound, err := StringExistsInFile("rpcallowip=", chd+cConfFileGroestlcoin)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileGroestlcoin, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cConfFileGroestlcoin, "rpcallowip=192.168.1.0/255.255.255.0"); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcport= info if required
		bNeedToWriteStr = true
		if FileExists(chd + cConfFileGroestlcoin) {
			bStrFound, err := StringExistsInFile("rpcport=", chd+cConfFileGroestlcoin)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cConfFileGroestlcoin, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cConfFileGroestlcoin, "rpcport="+CRPCPortGroestlcoin); err != nil {
				log.Fatal(err)
			}
		}

		return rpcu, rpcpw, nil
	case PTPhore:
		fmt.Println("Populating " + CPhoreConfFile + " for initial setup...")

		// Add rpcuser info if required
		b, err := StringExistsInFile(cRPCUserStr+"=", chd+CPhoreConfFile)
		if err != nil {
			return "", "", fmt.Errorf("unable to search for text in file - %v", err)
		}
		if !b {
			if !bFileHasBeenBU {
				bFileHasBeenBU = true
				if err := BackupFile(chd, CPhoreConfFile, "", "", false); err != nil {
					return "", "", fmt.Errorf("unable to backup file - %v", err)
				}
			}
			rpcu = cPhoreRPCUser
			if err := WriteTextToFile(chd+CPhoreConfFile, cRPCUserStr+"="+rpcu); err != nil {
				log.Fatal(err)
			}
		} else {
			rpcu, err = GetStringAfterStrFromFile(cRPCUserStr+"=", chd+CPhoreConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
		}

		// Add rpcpassword info if required
		b, err = StringExistsInFile(cRPCPasswordStr+"=", chd+CPhoreConfFile)
		if err != nil {
			return "", "", fmt.Errorf("unable to search for text in file - %v", err)
		}
		if !b {
			if !bFileHasBeenBU {
				bFileHasBeenBU = true
				if err := BackupFile(chd, CPhoreConfFile, "", "", false); err != nil {
					return "", "", fmt.Errorf("unable to backup file - %v", err)
				}
			}
			rpcpw = rand.String(20)
			if err := WriteTextToFile(chd+CPhoreConfFile, cRPCPasswordStr+"="+rpcpw); err != nil {
				log.Fatal(err)
			}
			if err := WriteTextToFile(chd+CPhoreConfFile, ""); err != nil {
				log.Fatal(err)
			}
		} else {
			rpcpw, err = GetStringAfterStrFromFile(cRPCPasswordStr+"=", chd+CPhoreConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
		}

		// Add daemon=1 info if required
		b, err = StringExistsInFile("daemon=1", chd+CPhoreConfFile)
		if err != nil {
			return "", "", fmt.Errorf("unable to search for text in file - %v", err)
		}
		if !b {
			if !bFileHasBeenBU {
				bFileHasBeenBU = true
				if err := BackupFile(chd, CPhoreConfFile, "", "", false); err != nil {
					return "", "", fmt.Errorf("unable to backup file - %v", err)
				}
			}
			if err := WriteTextToFile(chd+CPhoreConfFile, "daemon=1"); err != nil {
				log.Fatal(err)
			}
			if err := WriteTextToFile(chd+CPhoreConfFile, ""); err != nil {
				log.Fatal(err)
			}
		}

		// Add server=1 info if required
		b, err = StringExistsInFile("server=1", chd+CPhoreConfFile)
		if err != nil {
			return "", "", fmt.Errorf("unable to search for text in file - %v", err)
		}
		if !b {
			if !bFileHasBeenBU {
				bFileHasBeenBU = true
				if err := BackupFile(chd, CPhoreConfFile, "", "", false); err != nil {
					return "", "", fmt.Errorf("unable to backup file - %v", err)
				}
			}
			if err := WriteTextToFile(chd+CPhoreConfFile, "server=1"); err != nil {
				log.Fatal(err)
			}
		}
		// Add rpcallowip= info if required
		b, err = StringExistsInFile("rpcallowip=", chd+CPhoreConfFile)
		if err != nil {
			return "", "", fmt.Errorf("unable to search for text in file - %v", err)
		}
		if !b {
			if !bFileHasBeenBU {
				bFileHasBeenBU = true
				if err := BackupFile(chd, CPhoreConfFile, "", "", false); err != nil {
					return "", "", fmt.Errorf("unable to backup file - %v", err)
				}
			}
			if err := WriteTextToFile(chd+CPhoreConfFile, "rpcallowip=192.168.1.0/255.255.255.0"); err != nil {
				log.Fatal(err)
			}
		}
		// Add rpcport= info if required
		b, err = StringExistsInFile("rpcport=", chd+CPhoreConfFile)
		if err != nil {
			return "", "", fmt.Errorf("unable to search for text in file - %v", err)
		}
		if !b {
			if !bFileHasBeenBU {
				bFileHasBeenBU = true
				if err := BackupFile(chd, CPhoreConfFile, "", "", false); err != nil {
					return "", "", fmt.Errorf("unable to backup file - %v", err)
				}
			}
			if err := WriteTextToFile(chd+CPhoreConfFile, "rpcport=11772"); err != nil {
				log.Fatal(err)
			}
		}
		return rpcu, rpcpw, nil
	case PTPIVX:
		fmt.Println("Populating " + CPIVXConfFile + " for initial setup...")

		// Add rpcuser info if required, or retrieve the existing one
		bNeedToWriteStr := true
		if FileExists(chd + CPIVXConfFile) {
			bStrFound, err := StringExistsInFile(cRPCUserStr+"=", chd+CPIVXConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CPIVXConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
				rpcu, err = GetStringAfterStrFromFile(cRPCUserStr+"=", chd+CPIVXConfFile)
				if err != nil {
					return "", "", fmt.Errorf("unable to search for text in file - %v", err)
				}
			}
		} else {
			// Set this to true, because the file has just been freshly created and we don't want to back it up
			bFileHasBeenBU = true
		}
		if bNeedToWriteStr {
			rpcu = cPIVXRPCUser
			if err := WriteTextToFile(chd+CPIVXConfFile, cRPCUserStr+"="+rpcu); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcpassword info if required, or retrieve the existing one
		bNeedToWriteStr = true
		if FileExists(chd + CPIVXConfFile) {
			bStrFound, err := StringExistsInFile(cRPCPasswordStr+"=", chd+CPIVXConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CPIVXConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
				rpcpw, err = GetStringAfterStrFromFile(cRPCPasswordStr+"=", chd+CPIVXConfFile)
				if err != nil {
					return "", "", fmt.Errorf("unable to search for text in file - %v", err)
				}
			}
		}
		if bNeedToWriteStr {
			rpcpw = rand.String(20)
			if err := WriteTextToFile(chd+CPIVXConfFile, cRPCPasswordStr+"="+rpcpw); err != nil {
				log.Fatal(err)
			}
			if err := WriteTextToFile(chd+CPIVXConfFile, ""); err != nil {
				log.Fatal(err)
			}
		}

		// Add daemon=1 info if required
		bNeedToWriteStr = true
		if FileExists(chd + CPIVXConfFile) {
			bStrFound, err := StringExistsInFile("daemon=1", chd+CPIVXConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CPIVXConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+CPIVXConfFile, "daemon=1"); err != nil {
				log.Fatal(err)
			}
			if err := WriteTextToFile(chd+CPIVXConfFile, ""); err != nil {
				log.Fatal(err)
			}
		}

		// Add server=1 info if required
		bNeedToWriteStr = true
		if FileExists(chd + CPIVXConfFile) {
			bStrFound, err := StringExistsInFile("server=1", chd+CPIVXConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CPIVXConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+CPIVXConfFile, "server=1"); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcallowip= info if required
		bNeedToWriteStr = true
		if FileExists(chd + CPIVXConfFile) {
			bStrFound, err := StringExistsInFile("rpcallowip=", chd+CPIVXConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CPIVXConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+CPIVXConfFile, "rpcallowip=192.168.1.0/255.255.255.0"); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcport= info if required
		bNeedToWriteStr = true
		if FileExists(chd + CPIVXConfFile) {
			bStrFound, err := StringExistsInFile("rpcport=", chd+CPIVXConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CPIVXConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+CPIVXConfFile, "rpcport="+CPIVXRPCPort); err != nil {
				log.Fatal(err)
			}
		}

		return rpcu, rpcpw, nil
	case PTRapids:
		fmt.Println("Populating " + CRapidsConfFile + " for initial setup...")

		// Add rpcuser info if required, or retrieve the existing one
		bNeedToWriteStr := true
		if FileExists(chd + CRapidsConfFile) {
			bStrFound, err := StringExistsInFile(cRPCUserStr+"=", chd+CRapidsConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CRapidsConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
				rpcu, err = GetStringAfterStrFromFile(cRPCUserStr+"=", chd+CRapidsConfFile)
				if err != nil {
					return "", "", fmt.Errorf("unable to search for text in file - %v", err)
				}
			}
		} else {
			// Set this to true, because the file has just been freshly created and we don't want to back it up
			bFileHasBeenBU = true
		}
		if bNeedToWriteStr {
			rpcu = cRapidsRPCUser
			if err := WriteTextToFile(chd+CRapidsConfFile, cRPCUserStr+"="+rpcu); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcpassword info if required, or retrieve the existing one
		bNeedToWriteStr = true
		if FileExists(chd + CRapidsConfFile) {
			bStrFound, err := StringExistsInFile(cRPCPasswordStr+"=", chd+CRapidsConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CRapidsConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
				rpcpw, err = GetStringAfterStrFromFile(cRPCPasswordStr+"=", chd+CRapidsConfFile)
				if err != nil {
					return "", "", fmt.Errorf("unable to search for text in file - %v", err)
				}
			}
		}
		if bNeedToWriteStr {
			rpcpw = rand.String(20)
			if err := WriteTextToFile(chd+CRapidsConfFile, cRPCPasswordStr+"="+rpcpw); err != nil {
				log.Fatal(err)
			}
			if err := WriteTextToFile(chd+CRapidsConfFile, ""); err != nil {
				log.Fatal(err)
			}
		}

		// Add daemon=1 info if required
		bNeedToWriteStr = true
		if FileExists(chd + CRapidsConfFile) {
			bStrFound, err := StringExistsInFile("daemon=1", chd+CRapidsConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CRapidsConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+CRapidsConfFile, "daemon=1"); err != nil {
				log.Fatal(err)
			}
			if err := WriteTextToFile(chd+CRapidsConfFile, ""); err != nil {
				log.Fatal(err)
			}
		}

		// Add listen=0 info if required
		bNeedToWriteStr = true
		if FileExists(chd + CRapidsConfFile) {
			bStrFound, err := StringExistsInFile("listen=0", chd+CRapidsConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CRapidsConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+CRapidsConfFile, "listen=0"); err != nil {
				log.Fatal(err)
			}
		}

		// Add server=1 info if required
		bNeedToWriteStr = true
		if FileExists(chd + CRapidsConfFile) {
			bStrFound, err := StringExistsInFile("server=1", chd+CRapidsConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CRapidsConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+CRapidsConfFile, "server=1"); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcallowip= info if required
		bNeedToWriteStr = true
		if FileExists(chd + CRapidsConfFile) {
			bStrFound, err := StringExistsInFile("rpcallowip=", chd+CRapidsConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CRapidsConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+CRapidsConfFile, "rpcallowip=192.168.1.0/255.255.255.0"); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcport= info if required
		bNeedToWriteStr = true
		if FileExists(chd + CRapidsConfFile) {
			bStrFound, err := StringExistsInFile("rpcport=", chd+CRapidsConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CRapidsConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+CRapidsConfFile, "rpcport="+CRapidsRPCPort); err != nil {
				log.Fatal(err)
			}
		}

		return rpcu, rpcpw, nil
	case PTReddCoin:
		fmt.Println("Populating " + CReddCoinConfFile + " for initial setup...")

		// Add rpcuser info if required, or retrieve the existing one
		bNeedToWriteStr := true
		if FileExists(chd + CReddCoinConfFile) {
			bStrFound, err := StringExistsInFile(cRPCUserStr+"=", chd+CReddCoinConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CReddCoinConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
				rpcu, err = GetStringAfterStrFromFile(cRPCUserStr+"=", chd+CReddCoinConfFile)
				if err != nil {
					return "", "", fmt.Errorf("unable to search for text in file - %v", err)
				}
			}
		} else {
			// Set this to true, because the file has just been freshly created and we don't want to back it up
			bFileHasBeenBU = true
		}
		if bNeedToWriteStr {
			rpcu = cReddCoinRPCUser
			if err := WriteTextToFile(chd+CReddCoinConfFile, cRPCUserStr+"="+rpcu); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcpassword info if required, or retrieve the existing one
		bNeedToWriteStr = true
		if FileExists(chd + CReddCoinConfFile) {
			bStrFound, err := StringExistsInFile(cRPCPasswordStr+"=", chd+CReddCoinConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CReddCoinConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
				rpcpw, err = GetStringAfterStrFromFile(cRPCPasswordStr+"=", chd+CReddCoinConfFile)
				if err != nil {
					return "", "", fmt.Errorf("unable to search for text in file - %v", err)
				}
			}
		}
		if bNeedToWriteStr {
			rpcpw = rand.String(20)
			if err := WriteTextToFile(chd+CReddCoinConfFile, cRPCPasswordStr+"="+rpcpw); err != nil {
				log.Fatal(err)
			}
			if err := WriteTextToFile(chd+CReddCoinConfFile, ""); err != nil {
				log.Fatal(err)
			}
		}

		// Add daemon=1 info if required
		bNeedToWriteStr = true
		if FileExists(chd + CReddCoinConfFile) {
			bStrFound, err := StringExistsInFile("daemon=1", chd+CReddCoinConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CReddCoinConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+CReddCoinConfFile, "daemon=1"); err != nil {
				log.Fatal(err)
			}
			if err := WriteTextToFile(chd+CReddCoinConfFile, ""); err != nil {
				log.Fatal(err)
			}
		}

		// Add server=1 info if required
		bNeedToWriteStr = true
		if FileExists(chd + CReddCoinConfFile) {
			bStrFound, err := StringExistsInFile("server=1", chd+CReddCoinConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CReddCoinConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+CReddCoinConfFile, "server=1"); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcallowip= info if required
		bNeedToWriteStr = true
		if FileExists(chd + CReddCoinConfFile) {
			bStrFound, err := StringExistsInFile("rpcallowip=", chd+CReddCoinConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CReddCoinConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+CReddCoinConfFile, "rpcallowip=192.168.1.0/255.255.255.0"); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcport= info if required
		bNeedToWriteStr = true
		if FileExists(chd + CReddCoinConfFile) {
			bStrFound, err := StringExistsInFile("rpcport=", chd+CReddCoinConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CReddCoinConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+CReddCoinConfFile, "rpcport="+CReddCoinRPCPort); err != nil {
				log.Fatal(err)
			}
		}

		return rpcu, rpcpw, nil
	case PTScala:
		rpcu = "scalarpc"
		rpcpw = rand.String(20)

		return rpcu, rpcpw, nil
	case PTSyscoin:
		fmt.Println("Populating " + cSyscoinConfFile + " for initial setup...")

		// Add rpcuser info if required, or retrieve the existing one
		bNeedToWriteStr := true
		if FileExists(chd + cSyscoinConfFile) {
			bStrFound, err := StringExistsInFile(cRPCUserStr+"=", chd+cSyscoinConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cSyscoinConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
				rpcu, err = GetStringAfterStrFromFile(cRPCUserStr+"=", chd+cSyscoinConfFile)
				if err != nil {
					return "", "", fmt.Errorf("unable to search for text in file - %v", err)
				}
			}
		} else {
			// Set this to true, because the file has just been freshly created and we don't want to back it up
			bFileHasBeenBU = true
		}
		if bNeedToWriteStr {
			rpcu = CSyscoinRPCUser
			if err := WriteTextToFile(chd+cSyscoinConfFile, cRPCUserStr+"="+rpcu); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcpassword info if required, or retrieve the existing one
		bNeedToWriteStr = true
		if FileExists(chd + cSyscoinConfFile) {
			bStrFound, err := StringExistsInFile(cRPCPasswordStr+"=", chd+cSyscoinConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cSyscoinConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
				rpcpw, err = GetStringAfterStrFromFile(cRPCPasswordStr+"=", chd+cSyscoinConfFile)
				if err != nil {
					return "", "", fmt.Errorf("unable to search for text in file - %v", err)
				}
			}
		}
		if bNeedToWriteStr {
			rpcpw = rand.String(20)
			if err := WriteTextToFile(chd+cSyscoinConfFile, cRPCPasswordStr+"="+rpcpw); err != nil {
				log.Fatal(err)
			}
			if err := WriteTextToFile(chd+cSyscoinConfFile, ""); err != nil {
				log.Fatal(err)
			}
		}

		// Add daemon=1 info if required
		bNeedToWriteStr = true
		if FileExists(chd + cSyscoinConfFile) {
			bStrFound, err := StringExistsInFile("daemon=1", chd+cSyscoinConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cSyscoinConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cSyscoinConfFile, "daemon=1"); err != nil {
				log.Fatal(err)
			}
			if err := WriteTextToFile(chd+cSyscoinConfFile, ""); err != nil {
				log.Fatal(err)
			}
		}

		// Add server=1 info if required
		bNeedToWriteStr = true
		if FileExists(chd + cSyscoinConfFile) {
			bStrFound, err := StringExistsInFile("server=1", chd+cSyscoinConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cSyscoinConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cSyscoinConfFile, "server=1"); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcallowip= info if required
		bNeedToWriteStr = true
		if FileExists(chd + cSyscoinConfFile) {
			bStrFound, err := StringExistsInFile("rpcallowip=", chd+cSyscoinConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cSyscoinConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cSyscoinConfFile, "rpcallowip=192.168.1.0/255.255.255.0"); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcport= info if required
		bNeedToWriteStr = true
		if FileExists(chd + cSyscoinConfFile) {
			bStrFound, err := StringExistsInFile("rpcport=", chd+cSyscoinConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cSyscoinConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cSyscoinConfFile, "rpcport="+CSyscoinRPCPort); err != nil {
				log.Fatal(err)
			}
		}

		return rpcu, rpcpw, nil
	case PTTrezarcoin:
		fmt.Println("Populating " + cTrezarcoinConfFile + " for initial setup...")

		// Add rpcuser info if required, or retrieve the existing one
		bNeedToWriteStr := true
		if FileExists(chd + cTrezarcoinConfFile) {
			bStrFound, err := StringExistsInFile(cRPCUserStr+"=", chd+cTrezarcoinConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cTrezarcoinConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
				rpcu, err = GetStringAfterStrFromFile(cRPCUserStr+"=", chd+cTrezarcoinConfFile)
				if err != nil {
					return "", "", fmt.Errorf("unable to search for text in file - %v", err)
				}
			}
		} else {
			// Set this to true, because the file has just been freshly created and we don't want to back it up
			bFileHasBeenBU = true
		}
		if bNeedToWriteStr {
			rpcu = cTrezarcoinRPCUser
			if err := WriteTextToFile(chd+cTrezarcoinConfFile, cRPCUserStr+"="+rpcu); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcpassword info if required, or retrieve the existing one
		bNeedToWriteStr = true
		if FileExists(chd + cTrezarcoinConfFile) {
			bStrFound, err := StringExistsInFile(cRPCPasswordStr+"=", chd+cTrezarcoinConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cTrezarcoinConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
				rpcpw, err = GetStringAfterStrFromFile(cRPCPasswordStr+"=", chd+cTrezarcoinConfFile)
				if err != nil {
					return "", "", fmt.Errorf("unable to search for text in file - %v", err)
				}
			}
		}
		if bNeedToWriteStr {
			rpcpw = rand.String(20)
			if err := WriteTextToFile(chd+cTrezarcoinConfFile, cRPCPasswordStr+"="+rpcpw); err != nil {
				log.Fatal(err)
			}
			if err := WriteTextToFile(chd+cTrezarcoinConfFile, ""); err != nil {
				log.Fatal(err)
			}
		}

		// Add daemon=1 info if required
		bNeedToWriteStr = true
		if FileExists(chd + cTrezarcoinConfFile) {
			bStrFound, err := StringExistsInFile("daemon=1", chd+cTrezarcoinConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cTrezarcoinConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cTrezarcoinConfFile, "daemon=1"); err != nil {
				log.Fatal(err)
			}
			if err := WriteTextToFile(chd+cTrezarcoinConfFile, ""); err != nil {
				log.Fatal(err)
			}
		}

		// Add server=1 info if required
		bNeedToWriteStr = true
		if FileExists(chd + cTrezarcoinConfFile) {
			bStrFound, err := StringExistsInFile("server=1", chd+cTrezarcoinConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cTrezarcoinConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cTrezarcoinConfFile, "server=1"); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcallowip= info if required
		bNeedToWriteStr = true
		if FileExists(chd + cTrezarcoinConfFile) {
			bStrFound, err := StringExistsInFile("rpcallowip=", chd+cTrezarcoinConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cTrezarcoinConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cTrezarcoinConfFile, "rpcallowip=192.168.1.0/255.255.255.0"); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcport= info if required
		bNeedToWriteStr = true
		if FileExists(chd + cTrezarcoinConfFile) {
			bStrFound, err := StringExistsInFile("rpcport=", chd+cTrezarcoinConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, cTrezarcoinConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+cTrezarcoinConfFile, "rpcport="+CTrezarcoinRPCPort); err != nil {
				log.Fatal(err)
			}
		}

		return rpcu, rpcpw, nil
	case PTVertcoin:
		fmt.Println("Populating " + CVertcoinConfFile + " for initial setup...")

		// Add rpcuser info if required, or retrieve the existing one
		bNeedToWriteStr := true
		if FileExists(chd + CVertcoinConfFile) {
			bStrFound, err := StringExistsInFile(cRPCUserStr+"=", chd+CVertcoinConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CVertcoinConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
				rpcu, err = GetStringAfterStrFromFile(cRPCUserStr+"=", chd+CVertcoinConfFile)
				if err != nil {
					return "", "", fmt.Errorf("unable to search for text in file - %v", err)
				}
			}
		} else {
			// Set this to true, because the file has just been freshly created and we don't want to back it up
			bFileHasBeenBU = true
		}
		if bNeedToWriteStr {
			rpcu = cVertcoinRPCUser
			if err := WriteTextToFile(chd+CVertcoinConfFile, cRPCUserStr+"="+rpcu); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcpassword info if required, or retrieve the existing one
		bNeedToWriteStr = true
		if FileExists(chd + CVertcoinConfFile) {
			bStrFound, err := StringExistsInFile(cRPCPasswordStr+"=", chd+CVertcoinConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CVertcoinConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
				rpcpw, err = GetStringAfterStrFromFile(cRPCPasswordStr+"=", chd+CVertcoinConfFile)
				if err != nil {
					return "", "", fmt.Errorf("unable to search for text in file - %v", err)
				}
			}
		}
		if bNeedToWriteStr {
			rpcpw = rand.String(20)
			if err := WriteTextToFile(chd+CVertcoinConfFile, cRPCPasswordStr+"="+rpcpw); err != nil {
				log.Fatal(err)
			}
			if err := WriteTextToFile(chd+CVertcoinConfFile, ""); err != nil {
				log.Fatal(err)
			}
		}

		// Add daemon=1 info if required
		bNeedToWriteStr = true
		if FileExists(chd + CVertcoinConfFile) {
			bStrFound, err := StringExistsInFile("daemon=1", chd+CVertcoinConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CVertcoinConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+CVertcoinConfFile, "daemon=1"); err != nil {
				log.Fatal(err)
			}
			if err := WriteTextToFile(chd+CVertcoinConfFile, ""); err != nil {
				log.Fatal(err)
			}
		}

		// Add server=1 info if required
		bNeedToWriteStr = true
		if FileExists(chd + CVertcoinConfFile) {
			bStrFound, err := StringExistsInFile("server=1", chd+CVertcoinConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CVertcoinConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+CVertcoinConfFile, "server=1"); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcallowip= info if required
		bNeedToWriteStr = true
		if FileExists(chd + CVertcoinConfFile) {
			bStrFound, err := StringExistsInFile("rpcallowip=", chd+CVertcoinConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CVertcoinConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+CVertcoinConfFile, "rpcallowip=192.168.1.0/255.255.255.0"); err != nil {
				log.Fatal(err)
			}
		}

		// Add rpcport= info if required
		bNeedToWriteStr = true
		if FileExists(chd + CVertcoinConfFile) {
			bStrFound, err := StringExistsInFile("rpcport=", chd+CVertcoinConfFile)
			if err != nil {
				return "", "", fmt.Errorf("unable to search for text in file - %v", err)
			}
			if !bStrFound {
				// String not found
				if !bFileHasBeenBU {
					bFileHasBeenBU = true
					if err := BackupFile(chd, CVertcoinConfFile, "", "", false); err != nil {
						return "", "", fmt.Errorf("unable to backup file - %v", err)
					}
				}
			} else {
				bNeedToWriteStr = false
			}
		}
		if bNeedToWriteStr {
			if err := WriteTextToFile(chd+CVertcoinConfFile, "rpcport="+CVertcoinRPCPort); err != nil {
				log.Fatal(err)
			}
		}

		return rpcu, rpcpw, nil
	default:
		err = errors.New("unable to determine ProjectType")
	}
	return "", "", nil
}

func AllProjectBinaryFilesExists() (bool, error) {
	bwconf, err := GetConfigStruct("", false)
	if err != nil {
		return false, fmt.Errorf("unable to GetConfigStruct - %v", err)
	}

	var abf string
	abf, err = GetAppWorkingFolder()
	if err != nil {
		return false, fmt.Errorf("Unable to GetAppsBinFolder - %v ", err)
	}

	//ex, err := os.Executable()
	//if err != nil {
	//	return false, fmt.Errorf("Unable to retrieve running binary: %v ", err)
	//}
	//abf := AddTrailingSlash(filepath.Dir(ex))

	switch bwconf.ProjectType {
	case PTBitcoinPlus:
		if runtime.GOOS == "windows" {
			if !FileExists(abf + CCliFileWinBitcoinPlus) {
				return false, nil
			}
			if !FileExists(abf + CDFileWinBitcoinPlus) {
				return false, nil
			}
			if !FileExists(abf + CTxFileWinBitcoinPlus) {
				return false, nil
			}
		} else {
			if !FileExists(abf + CCliFileBitcoinPlus) {
				return false, nil
			}
			if !FileExists(abf + CDFileBitcoinPlus) {
				return false, nil
			}
			if !FileExists(abf + CTxFileBitcoinPlus) {
				return false, nil
			}
		}
	case PTDenarius:
		if runtime.GOOS == "windows" {
			if !FileExists(abf + CCliFileWinDenarius) {
				return false, nil
			}
			if !FileExists(abf + CDFileWinDenarius) {
				return false, nil
			}
		} else {
			if !FileExists(CBinDirLinuxDenarius + CCliFileDenarius) {
				return false, nil
			}
			if !FileExists(CBinDirLinuxDenarius + CDFileDenarius) {
				return false, nil
			}
		}
	case PTDeVault:
		if runtime.GOOS == "windows" {
			if !FileExists(abf + CCliFileWinDeVault) {
				return false, nil
			}
			if !FileExists(abf + CDFileWinDeVault) {
				return false, nil
			}
			if !FileExists(abf + CTxFileWinDeVault) {
				return false, nil
			}
		} else {
			if !FileExists(abf + CCliFileDeVault) {
				return false, nil
			}
			if !FileExists(abf + CDFileDeVault) {
				return false, nil
			}
			if !FileExists(abf + CTxFileDeVault) {
				return false, nil
			}
		}
	case PTDigiByte:
		if runtime.GOOS == "windows" {
			if !FileExists(abf + CCliFileWinDigiByte) {
				return false, nil
			}
			if !FileExists(abf + CDFileWinDigiByte) {
				return false, nil
			}
			if !FileExists(abf + CTxFileWinDigiByte) {
				return false, nil
			}
		} else {
			if !FileExists(abf + CCliFileDigiByte) {
				return false, nil
			}
			if !FileExists(abf + CDFileDigiByte) {
				return false, nil
			}
			if !FileExists(abf + CTxFileDigiByte) {
				return false, nil
			}
		}
	case PTDivi:
		if runtime.GOOS == "windows" {
			if !FileExists(abf + CDiviCliFileWin) {
				return false, nil
			}
			if !FileExists(abf + CDiviDFileWin) {
				return false, nil
			}
			if !FileExists(abf + CDiviTxFileWin) {
				return false, nil
			}
		} else {
			if !FileExists(abf + CDiviCliFile) {
				return false, nil
			}
			if !FileExists(abf + CDiviDFile) {
				return false, nil
			}
			if !FileExists(abf + CDiviTxFile) {
				return false, nil
			}
		}
	case PTFeathercoin:
		if runtime.GOOS == "windows" {
			if !FileExists(abf + CCliFileWinFeathercoin) {
				return false, nil
			}
			if !FileExists(abf + CDFileWinFeathercoin) {
				return false, nil
			}
			if !FileExists(abf + CTxFileWinFeathercoin) {
				return false, nil
			}
		} else {
			if !FileExists(abf + CCliFileFeathercoin) {
				return false, nil
			}
			if !FileExists(abf + CDFileFeathercoin) {
				return false, nil
			}
			if !FileExists(abf + CTxFileFeathercoin) {
				return false, nil
			}
		}
	case PTGroestlcoin:
		if runtime.GOOS == "windows" {
			if !FileExists(abf + CCliFileWinGroestlcoin) {
				return false, nil
			}
			if !FileExists(abf + CDFileWinGroestlcoin) {
				return false, nil
			}
			if !FileExists(abf + CTxFileWinGroestlcoin) {
				return false, nil
			}
		} else {
			if !FileExists(abf + CCliFileGroestlcoin) {
				return false, nil
			}
			if !FileExists(abf + CDFileGroestlcoin) {
				return false, nil
			}
			if !FileExists(abf + CTxFileGroestlcoin) {
				return false, nil
			}
		}
	case PTPhore:
		if runtime.GOOS == "windows" {
			if !FileExists(abf + CPhoreCliFileWin) {
				return false, nil
			}
			if !FileExists(abf + CPhoreDFileWin) {
				return false, nil
			}
			if !FileExists(abf + CPhoreTxFileWin) {
				return false, nil
			}
		} else {
			if !FileExists(abf + CPhoreCliFile) {
				return false, nil
			}
			if !FileExists(abf + CPhoreDFile) {
				return false, nil
			}
			if !FileExists(abf + CPhoreTxFile) {
				return false, nil
			}
		}
	case PTPIVX:
		if runtime.GOOS == "windows" {
			if !FileExists(abf + CPIVXCliFileWin) {
				return false, nil
			}
			if !FileExists(abf + CPIVXDFileWin) {
				return false, nil
			}
			if !FileExists(abf + CPIVXTxFileWin) {
				return false, nil
			}
		} else {
			if !FileExists(abf + CPIVXCliFile) {
				return false, nil
			}
			if !FileExists(abf + CPIVXDFile) {
				return false, nil
			}
			if !FileExists(abf + CPIVXTxFile) {
				return false, nil
			}
		}
	case PTRapids:
		if runtime.GOOS == "windows" {
			if !FileExists(abf + CRapidsCliFileWin) {
				return false, nil
			}
			if !FileExists(abf + CRapidsDFileWin) {
				return false, nil
			}
			if !FileExists(abf + CRapidsTxFileWin) {
				return false, nil
			}
		} else {
			if !FileExists(abf + CRapidsCliFile) {
				return false, nil
			}
			if !FileExists(abf + CRapidsDFile) {
				return false, nil
			}
			if !FileExists(abf + CRapidsTxFile) {
				return false, nil
			}
		}
	case PTReddCoin:
		if runtime.GOOS == "windows" {
			if !FileExists(abf + CReddCoinCliFileWin) {
				return false, nil
			}
			if !FileExists(abf + CReddCoinDFileWin) {
				return false, nil
			}
			if !FileExists(abf + CReddCoinTxFileWin) {
				return false, nil
			}
		} else {
			if !FileExists(abf + CReddCoinCliFile) {
				return false, nil
			}
			if !FileExists(abf + CReddCoinDFile) {
				return false, nil
			}
			if !FileExists(abf + CReddCoinTxFile) {
				return false, nil
			}
		}
	case PTScala:
		if runtime.GOOS == "windows" {
			if !FileExists(abf + CScalaCliFileWin) {
				return false, nil
			}
			if !FileExists(abf + CScalaDFileWin) {
				return false, nil
			}
			if !FileExists(abf + CScalaTxFileWin) {
				return false, nil
			}
		} else {
			if !FileExists(abf + CScalaCliFile) {
				return false, nil
			}
			if !FileExists(abf + CScalaDFile) {
				return false, nil
			}
			if !FileExists(abf + CScalaTxFile) {
				return false, nil
			}
		}
	case PTSyscoin:
		if runtime.GOOS == "windows" {
			if !FileExists(abf + CSyscoinCliFileWin) {
				return false, nil
			}
			if !FileExists(abf + CSyscoinDFileWin) {
				return false, nil
			}
			if !FileExists(abf + CSyscoinTxFileWin) {
				return false, nil
			}
		} else {
			if !FileExists(abf + CSyscoinCliFile) {
				return false, nil
			}
			if !FileExists(abf + CSyscoinDFile) {
				return false, nil
			}
			if !FileExists(abf + CSyscoinTxFile) {
				return false, nil
			}
		}
	case PTTrezarcoin:
		if runtime.GOOS == "windows" {
			if !FileExists(abf + CTrezarcoinCliFileWin) {
				return false, nil
			}
			if !FileExists(abf + CTrezarcoinDFileWin) {
				return false, nil
			}
			if !FileExists(abf + CTrezarcoinTxFileWin) {
				return false, nil
			}
		} else {
			if !FileExists(abf + CTrezarcoinCliFile) {
				return false, nil
			}
			if !FileExists(abf + CTrezarcoinDFile) {
				return false, nil
			}
			if !FileExists(abf + CTrezarcoinTxFile) {
				return false, nil
			}
		}
	case PTVertcoin:
		if runtime.GOOS == "windows" {
			if !FileExists(abf + CVertcoinCliFileWin) {
				return false, nil
			}
			if !FileExists(abf + CVertcoinDFileWin) {
				return false, nil
			}
			if !FileExists(abf + CVertcoinTxFileWin) {
				return false, nil
			}
		} else {
			if !FileExists(abf + CVertcoinCliFile) {
				return false, nil
			}
			if !FileExists(abf + CVertcoinDFile) {
				return false, nil
			}
			if !FileExists(abf + CVertcoinTxFile) {
				return false, nil
			}
		}
	default:
		err = errors.New("unable to determine ProjectType - AllProjectBinaryFilesExists")
		return false, err
	}

	return true, nil
}

func UpdateAUDPriceInfo() error {
	resp, err := http.Get("https://api.exchangeratesapi.io/latest?base=USD&symbols=AUD")
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	err = json.Unmarshal(body, &gPricePerCoinAUD)
	if err != nil {
		return err
	}
	return errors.New("unable to updateAUDPriceInfo")
}

func UpdateGBPPriceInfo() error {
	resp, err := http.Get("https://api.exchangeratesapi.io/latest?base=USD&symbols=GBP")
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	body, err := ioutil.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	err = json.Unmarshal(body, &gPricePerCoinGBP)
	if err != nil {
		return err
	}
	return errors.New("unable to updateGBPPriceInfo")
}

func WalletFix(wft WalletFixType, pt ProjectType) error {
	cn, err := GetCoinName(APPTCLI)
	if err != nil {
		return fmt.Errorf("unable to retrieve coin name")
	}

	// Stop the coin daemon if it's running
	if err := StopCoinDaemon(false); err != nil {
		return fmt.Errorf("unable to stop the "+cn+" coin daemon: %v", err)
	}

	abf, _ := GetAppWorkingFolder()

	//ex, err := os.Executable()
	//if err != nil {
	//	return fmt.Errorf("Unable to retrieve running binary: %v ", err)
	//}
	//abf := AddTrailingSlash(filepath.Dir(ex))

	//bwconf, err := GetConfigStruct("", false)
	//if err != nil {
	//	return err
	//}

	coind, err := GetCoinDaemonFilename(APPTCLI, pt)
	if err != nil {
		return fmt.Errorf("unable to GetCoinDaemonFilename - %v", err)
	}

	var arg1 string
	switch wft {
	case WFTReIndex:
		arg1 = "-reindex"
	case WFTReSync:
		arg1 = "-resync"
	default:
		return fmt.Errorf("unable to determine WalletFixType - [WalletFix-" + cn + "]")
	}

	cRun := exec.Command(abf+coind, arg1)
	if err := cRun.Run(); err != nil {
		return fmt.Errorf("unable to run "+coind+" "+arg1+": %v", err)
	}

	return nil
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

func ShouldWeRunHealthCheck() (bool, error) {
	bwconf, err := GetConfigStruct("", false)
	if err != nil {
		return false, fmt.Errorf("unable to GetConfigStruct - %v", err)
	}

	t := time.Now()
	s := t.Format("15:04")
	if bwconf.LastHealthCheck == cUnknown {
		if bwconf.RunHealthCheckAt == s {
			// Run the health check
			return true, nil
		}
	}

	lrd := t.Format("2006-01-02")
	if lrd != bwconf.LastHealthCheck {
		// Check the time and run if it matches
		if bwconf.RunHealthCheckAt == s {
			// Run the health check
			return true, nil
		}
	}

	return false, nil
}

// StartCoinDaemon - Run the coins Daemon e.g. Run divid
func StartCoinDaemon(displayOutput bool) error {
	bwconf, err := GetConfigStruct("", false)
	if err != nil {
		return err
	}

	idr, _, _ := IsCoinDaemonRunning(bwconf.ProjectType)
	if idr == true {
		// Already running...
		return nil
	}

	abf, _ := GetAppWorkingFolder()

	//ex, err := os.Executable()
	//if err != nil {
	//	return fmt.Errorf("Unable to retrieve running binary: %v ", err)
	//}
	//abf := AddTrailingSlash(filepath.Dir(ex)).

	switch bwconf.ProjectType {
	case PTBitcoinPlus:
		if runtime.GOOS == "windows" {
			//_ = exec.Command(GetAppsBinFolder() + cDiviDFileWin)
			fp := abf + CDiviDFileWin
			cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
			if err := cmd.Run(); err != nil {
				return err
			}
		} else {
			if displayOutput {
				fmt.Println("Attempting to run the bitcoinplusd daemon...")
			}

			cmdRun := exec.Command(abf + CDFileBitcoinPlus)
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
				if string(line) == "BitcoinPlus server starting" {
					if displayOutput {
						fmt.Println("BitcoinPlus server starting")
					}
					return nil
				} else {
					return errors.New("unable to start BitcoinPlus server: " + string(line))
				}
			}
		}
	case PTDenarius:
		if runtime.GOOS == "windows" {
			fp := abf + CDFileWinDenarius
			cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
			if err := cmd.Run(); err != nil {
				return err
			}
		} else {
			if displayOutput {
				fmt.Println("Attempting to run the denariusd daemon...")
			}

			cmdRun := exec.Command(CBinDirLinuxDenarius + CDFileDenarius)
			//stdout, err := cmdRun.StdoutPipe()
			if err != nil {
				return err
			}
			err = cmdRun.Start()
			if err != nil {
				return err
			}
			if displayOutput {
				fmt.Println("Denarius server starting")
			}

		}
	case PTDeVault:
		if runtime.GOOS == "windows" {
			//_ = exec.Command(GetAppsBinFolder() + cDiviDFileWin)
			fp := abf + CDFileWinDeVault
			cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
			if err := cmd.Run(); err != nil {
				return err
			}
		} else {
			if displayOutput {
				fmt.Println("Attempting to run the devault daemon...")
			}

			args := []string{"-bypasspassword"}
			cmdRun := exec.Command(abf+CDFileDeVault, args...)
			//stdout, err := cmdRun.StdoutPipe()
			if err != nil {
				return err
			}
			err = cmdRun.Start()
			if err != nil {
				return err
			}
			fmt.Println("DeVault server starting")
		}
	case PTDigiByte:
		if runtime.GOOS == "windows" {
			fp := abf + CDFileWinDigiByte
			cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
			if err := cmd.Run(); err != nil {
				return err
			}
		} else {
			if displayOutput {
				fmt.Println("Attempting to run the digibyted daemon...")
			}

			cmdRun := exec.Command(abf + CDFileDigiByte)
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
				if string(line) == "" { //"DigiByte server starting" {
					if displayOutput {
						fmt.Println("DigiByte server starting")
					}
					return nil
				} else {
					return errors.New("unable to start DigiByte server: " + string(line))
				}
			}
		}
	case PTDivi:
		if runtime.GOOS == "windows" {
			//_ = exec.Command(GetAppsBinFolder() + cDiviDFileWin)
			fp := abf + CDiviDFileWin
			cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
			if err := cmd.Run(); err != nil {
				return err
			}
		} else {
			if displayOutput {
				fmt.Println("Attempting to run the divid daemon...")
			}

			cmdRun := exec.Command(abf + CDiviDFile)
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
				if string(line) == "DIVI server starting" {
					if displayOutput {
						fmt.Println("DIVI server starting")
					}
					return nil
				} else {
					return errors.New("unable to start Divi server: " + string(line))
				}
			}
		}
	case PTFeathercoin:
		if runtime.GOOS == "windows" {
			//_ = exec.Command(GetAppsBinFolder() + cDiviDFileWin)
			fp := abf + CDFileWinFeathercoin
			cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
			if err := cmd.Run(); err != nil {
				return err
			}
		} else {
			if displayOutput {
				fmt.Println("Attempting to run the feathercoind daemon...")
			}

			cmdRun := exec.Command(abf + CDFileFeathercoin)
			//stdout, err := cmdRun.StdoutPipe()
			if err != nil {
				return err
			}
			err = cmdRun.Start()
			if err != nil {
				return err
			}
			fmt.Println("Feathercoin server starting")

			//buf := bufio.NewReader(stdout) // Notice that this is not in a loop
			//num := 1
			//for {
			//	line, _, _ := buf.ReadLine()
			//	if num > 3 {
			//		os.Exit(0)
			//	}
			//	num++
			//	if string(line) == "Feathercoin Core starting" {
			//		if displayOutput {
			//			fmt.Println("Feathercoin server starting")
			//		}
			//		return nil
			//	} else {
			//		return errors.New("unable to start Feathercoin server: " + string(line))
			//	}
			//}
		}
	case PTGroestlcoin:
		if runtime.GOOS == "windows" {
			//_ = exec.Command(GetAppsBinFolder() + cDiviDFileWin)
			fp := abf + CDFileWinGroestlcoin
			cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
			if err := cmd.Run(); err != nil {
				return err
			}
		} else {
			if displayOutput {
				fmt.Println("Attempting to run the groestlcoin daemon...")
			}

			cmdRun := exec.Command(abf + CDFileGroestlcoin)
			//stdout, err := cmdRun.StdoutPipe()
			if err != nil {
				return err
			}
			err = cmdRun.Start()
			if err != nil {
				return err
			}
			fmt.Println("Groestlcoin server starting")
		}
	case PTPhore:
		if runtime.GOOS == "windows" {
			fp := abf + CDiviDFileWin
			cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
			if err := cmd.Run(); err != nil {
				return err
			}
		} else {
			if displayOutput {
				fmt.Println("Attempting to run the phored daemon...")
			}

			cmdRun := exec.Command(abf + CPhoreDFile)
			stdout, err := cmdRun.StdoutPipe()
			if err != nil {
				return err
			}
			err = cmdRun.Start()
			if err != nil {
				return err
			}

			buf := bufio.NewReader(stdout) // Notice that this is not in a loop
			num := 1
			for {
				line, _, _ := buf.ReadLine()
				if num > 3 {
					os.Exit(0)
				}
				num++
				if string(line) == "Phore server starting" {
					if displayOutput {
						fmt.Println("Phore server starting")
					}
					return nil
				} else {
					return errors.New("unable to start Phore server: " + string(line))
				}
			}
		}
	case PTPIVX:
		if runtime.GOOS == "windows" {
			fp := abf + CPIVXDFileWin
			cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
			if err := cmd.Run(); err != nil {
				return err
			}
		} else {
			if displayOutput {
				fmt.Println("Attempting to run the pivxd daemon...")
			}

			cmdRun := exec.Command(abf + CPIVXDFile)
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
				if string(line) == "PIVX server starting" {
					if displayOutput {
						fmt.Println("PIVX server starting")
					}
					return nil
				} else {
					return errors.New("unable to start PIVX server: " + string(line))
				}
			}
		}
	case PTRapids:
		if runtime.GOOS == "windows" {
			fp := abf + CRapidsDFileWin
			cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
			if err := cmd.Run(); err != nil {
				return err
			}
		} else {
			if displayOutput {
				fmt.Println("Attempting to run the rapidsd daemon...")
			}

			cmdRun := exec.Command(abf + CRapidsDFile)
			stdout, err := cmdRun.StdoutPipe()
			if err != nil {
				return err
			}
			err = cmdRun.Start()
			if err != nil {
				return err
			}

			// Wait a few seconds before reading the output...
			time.Sleep(3 * time.Second)
			buf := bufio.NewReader(stdout)
			num := 1
			//bStarting := false
			//sIssue := ""
			for {
				line, _, _ := buf.ReadLine()
				if num > 10 {
					os.Exit(0)
				}
				num++
				//if string(line) == "RPD server starting" {
				//	bStarting = true
				//	}
				//if string(line) == "RPD server starting" {
				//	bStarting = true
				//}

				if string(line) == "RPD server starting" {
					if displayOutput {
						fmt.Println("Rapids server is starting...")
					}
					return nil
				} else {
					return errors.New("unable to start the Rapids server: " + string(line))
				}
			}
		}
	case PTReddCoin:
		if runtime.GOOS == "windows" {
			//_ = exec.Command(GetAppsBinFolder() + cDiviDFileWin)
			fp := abf + CReddCoinDFileWin
			cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
			if err := cmd.Run(); err != nil {
				return err
			}
		} else {
			if displayOutput {
				fmt.Println("Attempting to run the reddcoin daemon...")
			}

			cmdRun := exec.Command(abf + CReddCoinDFile)
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
				if string(line) == "Reddcoin server starting" {
					if displayOutput {
						fmt.Println("Reddcoin server starting")
					}
					return nil
				} else {
					fmt.Println("Have you installed these dependencies?\n\nlibssl1.0-dev libprotobuf17 libboost-thread1.62-dev libboost-program-options1.62-dev libboost-filesystem1.62-dev libboost-system1.62-dev")
					return errors.New("unable to start the Reddcoin server: " + string(line))
				}
			}

		}
	case PTScala:
		if runtime.GOOS == "windows" {
			//_ = exec.Command(GetAppsBinFolder() + cDiviDFileWin)
			fp := abf + CScalaDFileWin
			cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
			if err := cmd.Run(); err != nil {
				return err
			}
		} else {
			if displayOutput {
				fmt.Println("Attempting to run the scala daemon...")
			}

			args := []string{"--detach"}
			cmdRun := exec.Command(abf+CScalaDFile, args...)
			//stdout, err := cmdRun.StdoutPipe()
			if err != nil {
				return err
			}
			err = cmdRun.Start()
			if err != nil {
				return err
			}
			fmt.Println("Scala server starting")
		}
	case PTSyscoin:
		if runtime.GOOS == "windows" {
			fp := abf + CSyscoinDFileWin
			cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
			if err := cmd.Run(); err != nil {
				return err
			}
		} else {
			if displayOutput {
				fmt.Println("Attempting to run the denariusd daemon...")
			}

			cmdRun := exec.Command(abf + CSyscoinDFile)
			//stdout, err := cmdRun.StdoutPipe()
			if err != nil {
				return err
			}
			err = cmdRun.Start()
			if err != nil {
				return err
			}
			if displayOutput {
				fmt.Println("Denarius server starting")
			}

		}
	case PTTrezarcoin:
		if runtime.GOOS == "windows" {
			fp := abf + CDiviDFileWin
			cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
			if err := cmd.Run(); err != nil {
				return err
			}
		} else {
			if displayOutput {
				fmt.Println("Attempting to run the trezarcoin daemon...")
			}

			cmdRun := exec.Command(abf + CTrezarcoinDFile)
			stdout, err := cmdRun.StdoutPipe()
			if err != nil {
				return err
			}
			err = cmdRun.Start()
			if err != nil {
				return err
			}

			buf := bufio.NewReader(stdout) // Notice that this is not in a loop
			num := 1
			for {
				line, _, _ := buf.ReadLine()
				if num > 3 {
					os.Exit(0)
				}
				num++
				if string(line) == "Trezarcoin server starting" {
					if displayOutput {
						fmt.Println("Trezarcoin server starting")
					}
					return nil
				} else {
					return errors.New("unable to start Trezarcoin server: " + string(line))
				}
			}
		}
	case PTVertcoin:
		if runtime.GOOS == "windows" {
			//_ = exec.Command(GetAppsBinFolder() + cDiviDFileWin)
			fp := abf + CVertcoinDFileWin
			cmd := exec.Command("cmd.exe", "/C", "start", "/b", fp)
			if err := cmd.Run(); err != nil {
				return err
			}
		} else {
			if displayOutput {
				fmt.Println("Attempting to run the vertcoind daemon...")
			}

			cmdRun := exec.Command(abf + CVertcoinDFile)
			//stdout, err := cmdRun.StdoutPipe()
			if err != nil {
				return err
			}
			err = cmdRun.Start()
			if err != nil {
				return err
			}
			fmt.Println("Vertcoin server starting")
		}
	default:
		err = errors.New("unable to determine ProjectType")
	}
	return nil
}

// stopCoinDaemon - Stops the coin daemon (e.g. divid) from running
func StopCoinDaemon(displayOutput bool) error {
	bwconf, err := GetConfigStruct("", false)
	if err != nil {
		return err
	}

	idr, _, _ := IsCoinDaemonRunning(bwconf.ProjectType) //DiviDRunning()
	if idr != true {
		// Not running anyway ..
		return nil
	}

	abf, _ := GetAppWorkingFolder()

	//ex, err := os.Executable()
	//if err != nil {
	//	return fmt.Errorf("Unable to retrieve running binary: %v ", err)
	//}
	//abf := AddTrailingSlash(filepath.Dir(ex))

	coind, err := GetCoinDaemonFilename(APPTCLI, bwconf.ProjectType)
	if err != nil {
		return fmt.Errorf("unable to GetCoinDaemonFilename - %v", err)
	}

	switch bwconf.ProjectType {
	case PTDenarius:
		if runtime.GOOS == "windows" {
			// TODO Complete for Windows
		} else {
			cRun := exec.Command(abf+CCliFileDenarius, "stop")
			if err := cRun.Run(); err != nil {
				return fmt.Errorf("unable to StopPIVXD:%v", err)
			}

			for i := 0; i < 50; i++ {
				sr, _, _ := IsCoinDaemonRunning(PTDenarius)
				if !sr {
					return nil
				}
				if displayOutput {
					fmt.Printf("\rWaiting for denariusd server to stop %d/"+strconv.Itoa(50), i+1)
				}
				time.Sleep(3 * time.Second)

			}
		}
	case PTDivi:
		if runtime.GOOS == "windows" {
			// TODO Complete for Windows
		} else {
			for i := 0; i < 50; i++ {
				cRun := exec.Command(abf+CDiviCliFile, "stop")
				_ = cRun.Run()

				sr, _, _ := IsCoinDaemonRunning(PTDivi) //DiviDRunning()
				if !sr {
					// Lets wait a little longer before returning
					time.Sleep(3 * time.Second)
					return nil
				}
				if displayOutput {
					fmt.Printf("\rWaiting for divid server to stop %d/"+strconv.Itoa(50), i+1)
				}
				time.Sleep(3 * time.Second)
			}
		}
	case PTDigiByte:
		if runtime.GOOS == "windows" {
			// TODO Complete for Windows
		} else {
			for i := 0; i < 50; i++ {
				cRun := exec.Command(abf+CCliFileDigiByte, "stop")
				_ = cRun.Run()

				sr, _, _ := IsCoinDaemonRunning(PTDigiByte) //DigiByteDRunning()
				if !sr {
					// Lets wait a little longer before returning
					time.Sleep(3 * time.Second)
					return nil
				}
				if displayOutput {
					fmt.Printf("\rWaiting for DigiByte server to stop %d/"+strconv.Itoa(50), i+1)
				}
				time.Sleep(3 * time.Second)
			}
		}
	case PTFeathercoin:
		if runtime.GOOS == "windows" {
			// TODO Complete for Windows
		} else {
			for i := 0; i < 50; i++ {
				cRun := exec.Command(abf+CCliFileFeathercoin, "stop")
				_ = cRun.Run()

				sr, _, _ := IsCoinDaemonRunning(PTFeathercoin)
				if !sr {
					// Lets wait a little longer before returning
					time.Sleep(3 * time.Second)
					return nil
				}
				if displayOutput {
					fmt.Printf("\rWaiting for feathercoind server to stop %d/"+strconv.Itoa(50), i+1)
				}
				time.Sleep(3 * time.Second)
			}
		}
	case PTGroestlcoin:
		if runtime.GOOS == "windows" {
			// TODO Complete for Windows
		} else {
			for i := 0; i < 50; i++ {
				cRun := exec.Command(abf+CCliFileGroestlcoin, "stop")
				_ = cRun.Run()

				sr, _, _ := IsCoinDaemonRunning(PTGroestlcoin)
				if !sr {
					// Lets wait a little longer before returning
					time.Sleep(3 * time.Second)
					return nil
				}
				if displayOutput {
					fmt.Printf("\rWaiting for groestlcoind server to stop %d/"+strconv.Itoa(50), i+1)
				}
				time.Sleep(3 * time.Second)
			}
		}
	case PTPhore:
		if runtime.GOOS == "windows" {
			// TODO Complete for Windows
		} else {
			for i := 0; i < 50; i++ {
				cRun := exec.Command(abf+CPhoreCliFile, "stop")
				_ = cRun.Run()

				sr, _, _ := IsCoinDaemonRunning(PTPhore)
				if !sr {
					// Lets wait a little longer before returning
					time.Sleep(3 * time.Second)
					return nil
				}
				if displayOutput {
					fmt.Printf("\rWaiting for phored server to stop %d/"+strconv.Itoa(50), i+1)
				}
				time.Sleep(3 * time.Second)
			}
		}
	case PTPIVX:
		if runtime.GOOS == "windows" {
			// TODO Complete for Windows
		} else {
			cRun := exec.Command(abf+CPIVXCliFile, "stop")
			if err := cRun.Run(); err != nil {
				return fmt.Errorf("unable to StopPIVXD:%v", err)
			}

			for i := 0; i < 50; i++ {
				sr, _, _ := IsCoinDaemonRunning(PTPIVX)
				if !sr {
					return nil
				}
				if displayOutput {
					fmt.Printf("\rWaiting for pivxd server to stop %d/"+strconv.Itoa(50), i+1)
				}
				time.Sleep(3 * time.Second)

			}
		}
	case PTScala:
		if runtime.GOOS == "windows" {
			// TODO Complete for Windows
		} else {
			for i := 0; i < 50; i++ {
				cRun := exec.Command(abf+CScalaCliFile, "stop")
				_ = cRun.Run()

				sr, _, _ := IsCoinDaemonRunning(PTScala)
				if !sr {
					// Lets wait a little longer before returning
					time.Sleep(3 * time.Second)
					return nil
				}
				if displayOutput {
					fmt.Printf("\rWaiting for scala server to stop %d/"+strconv.Itoa(50), i+1)
				}
				time.Sleep(3 * time.Second)
			}
		}
	case PTSyscoin:
		if runtime.GOOS == "windows" {
			// TODO Complete for Windows
		} else {
			cRun := exec.Command(abf+CSyscoinCliFile, "stop")
			if err := cRun.Run(); err != nil {
				return fmt.Errorf("unable to StopSyscoinD:%v", err)
			}

			for i := 0; i < 50; i++ {
				sr, _, _ := IsCoinDaemonRunning(PTSyscoin)
				if !sr {
					return nil
				}
				if displayOutput {
					fmt.Printf("\rWaiting for Syscoind server to stop %d/"+strconv.Itoa(50), i+1)
				}
				time.Sleep(3 * time.Second)

			}
		}
	case PTTrezarcoin:
		if runtime.GOOS == "windows" {
			// TODO Complete for Windows
		} else {
			cRun := exec.Command(abf+CTrezarcoinCliFile, "stop")
			if err := cRun.Run(); err != nil {
				return fmt.Errorf("unable to StopCoinDaemon:%v", err)
			}

			for i := 0; i < 50; i++ {
				sr, _, _ := IsCoinDaemonRunning(PTTrezarcoin) //DiviDRunning()
				if !sr {
					return nil
				}
				if displayOutput {
					fmt.Printf("\rWaiting for "+coind+" server to stop %d/"+strconv.Itoa(50), i+1)
				}
				time.Sleep(3 * time.Second)

			}
		}
	case PTVertcoin:
		if runtime.GOOS == "windows" {
			// TODO Complete for Windows
		} else {
			for i := 0; i < 50; i++ {
				cRun := exec.Command(abf+CVertcoinCliFile, "stop")
				_ = cRun.Run()

				sr, _, _ := IsCoinDaemonRunning(PTVertcoin)
				if !sr {
					// Lets wait a little longer before returning
					time.Sleep(3 * time.Second)
					return nil
				}
				if displayOutput {
					fmt.Printf("\rWaiting for vertcoind server to stop %d/"+strconv.Itoa(50), i+1)
				}
				time.Sleep(3 * time.Second)
			}
		}
	default:
		err = errors.New("unable to determine ProjectType")
	}

	return nil
}

// RunInitialDaemon - Runs the divid Daemon for the first time to populate the divi.conf file
func RunInitialDaemon() (rpcuser, rpcpassword string, err error) {
	ex, err := os.Executable()
	if err != nil {
		return "", "", fmt.Errorf("Unable to retrieve running binary: %v ", err)
	}
	abf := AddTrailingSlash(filepath.Dir(ex))

	bwconf, err := GetConfigStruct("", false)
	if err != nil {
		return "", "", fmt.Errorf("unable to GetConfigStruct - %v", err)
	}

	coind, err := GetCoinDaemonFilename(APPTCLI, bwconf.ProjectType)
	if err != nil {
		return "", "", fmt.Errorf("unable to GetCoinDaemonFilename - %v", err)
	}

	switch bwconf.ProjectType {
	case PTDivi:
		//Run divid for the first time, so that we can get the outputted info to build the conf file
		fmt.Println("About to run " + coind + " for the first time...")
		cmdDividRun := exec.Command(abf + CDiviDFile)
		out, _ := cmdDividRun.CombinedOutput()
		fmt.Println("Populating " + cConfFileDivi + " for initial setup...")

		scanner := bufio.NewScanner(strings.NewReader(string(out)))
		var rpcuser, rpcpw string
		for scanner.Scan() {
			s := scanner.Text()
			if strings.Contains(s, cRPCUserStr) {
				rpcuser = strings.ReplaceAll(s, cRPCUserStr+"=", "")
			}
			if strings.Contains(s, cRPCPasswordStr) {
				rpcpw = strings.ReplaceAll(s, cRPCPasswordStr+"=", "")
			}
		}

		chd, _ := GetCoinHomeFolder(APPTCLI, bwconf.ProjectType)

		if err := WriteTextToFile(chd+cConfFileDivi, cRPCUserStr+"="+rpcuser); err != nil {
			log.Fatal(err)
		}
		if err := WriteTextToFile(chd+cConfFileDivi, cRPCPasswordStr+"="+rpcpw); err != nil {
			log.Fatal(err)
		}
		if err := WriteTextToFile(chd+cConfFileDivi, ""); err != nil {
			log.Fatal(err)
		}
		if err := WriteTextToFile(chd+cConfFileDivi, "daemon=1"); err != nil {
			log.Fatal(err)
		}
		if err := WriteTextToFile(chd+cConfFileDivi, ""); err != nil {
			log.Fatal(err)
		}
		if err := WriteTextToFile(chd+cConfFileDivi, "server=1"); err != nil {
			log.Fatal(err)
		}
		if err := WriteTextToFile(chd+cConfFileDivi, "rpcallowip=0.0.0.0/0"); err != nil {
			log.Fatal(err)
		}
		if err := WriteTextToFile(chd+cConfFileDivi, "rpcport=8332"); err != nil {
			log.Fatal(err)
		}

		// Now get a list of the latest "addnodes" and add them to the file:
		// I've commented out the below, as I think it might cause future issues with blockchain syncing,
		// because, I think that the ipaddresses in the conf file are used before any others are picked up,
		// so, it's possible that they could all go, and then cause issues.

		// gdc.AddToLog(lfp, "Adding latest master nodes to "+gdc.cConfFileDivi)
		// addnodes, _ := gdc.GetAddNodes()
		// sAddnodes := string(addnodes[:])
		// gdc.WriteTextToFile(dhd+gdc.cConfFileDivi, sAddnodes)

		return rpcuser, rpcpw, nil
	case PTTrezarcoin:
		//Run divid for the first time, so that we can get the outputted info to build the conf file
		fmt.Println("Attempting to run " + coind + " for the first time...")
		cmdTrezarCDRun := exec.Command(abf + coind)
		if err := cmdTrezarCDRun.Start(); err != nil {
			return "", "", fmt.Errorf("failed to start %v: %v", coind, err)
		}

		return "", "", nil

	default:
		err = errors.New("unable to determine ProjectType")
	}
	return "", "", nil
}

// StopDaemon - Send a "stop" to the daemon, and returns the result.
func StopDaemon(cliConf *ConfStruct) (GenericRespStruct, error) {
	var respStruct GenericRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"stop\",\"params\":[]}")
	req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port, body)
	if err != nil {
		return respStruct, err
	}
	req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
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

// StopDaemonMonero - Stops Monero based coin daemons
func StopDaemonMonero(cliConf *ConfStruct) (XLAStopDaemonRespStruct, error) {
	var respStruct XLAStopDaemonRespStruct

	//body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"stop_daemon\",\"params\":[]}")
	body := strings.NewReader("")
	req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port+"/stop_daemon", body)
	if err != nil {
		return respStruct, err
	}
	//req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword) //
	req.Header.Set("Content-Type", "application/json;")

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
	case PTDivi:
		// If the length of the address is not exactly 34 characters...
		if len(ad) != 34 {
			return false, nil
		}
		sFirst := ad[0]

		// 68 = UTF for D
		if sFirst != 68 {
			return false, nil
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

func WalletBackup(pt ProjectType) error {
	var abbrev, wl, destFolder string

	// First, work out what the coin type is
	var err error
	switch pt {
	case PTBitcoinPlus:
		abbrev = strings.ToLower(CCoinAbbrevBitcoinPlus)
		wl, err = GetCoinHomeFolder(APPTCLI, pt)
		if err != nil {
			return fmt.Errorf("unable to get coin home folder: %v", err)
		}
	case PTDenarius:
		abbrev = strings.ToLower(CCoinAbbrevDenarius)
		wl, err = GetCoinHomeFolder(APPTCLI, pt)
		if err != nil {
			return fmt.Errorf("unable to get coin home folder: %v", err)
		}
	case PTDeVault:
		abbrev = strings.ToLower(CCoinAbbrevDeVault)
		wl, err = GetCoinHomeFolder(APPTCLI, pt)
		if err != nil {
			return fmt.Errorf("unable to get coin home folder: %v", err)
		}
	case PTDigiByte:
		abbrev = strings.ToLower(CCoinAbbrevDigiByte)
		wl, err = GetCoinHomeFolder(APPTCLI, pt)
		if err != nil {
			return fmt.Errorf("unable to get coin home folder: %v", err)
		}
	case PTDivi:
		abbrev = strings.ToLower(CCoinAbbrevDivi)
		wl, err = GetCoinHomeFolder(APPTCLI, pt)
		if err != nil {
			return fmt.Errorf("unable to get coin home folder: %v", err)
		}
	case PTFeathercoin:
		abbrev = strings.ToLower(CCoinAbbrevFeathercoin)
		wl, err = GetCoinHomeFolder(APPTCLI, pt)
		if err != nil {
			return fmt.Errorf("unable to get coin home folder: %v", err)
		}
	case PTGroestlcoin:
		abbrev = strings.ToLower(CCoinAbbrevGroestlcoin)
		wl, err = GetCoinHomeFolder(APPTCLI, pt)
		if err != nil {
			return fmt.Errorf("unable to get coin home folder: %v", err)
		}
	case PTPhore:
		abbrev = strings.ToLower(CCoinAbbrevPhore)
		wl, err = GetCoinHomeFolder(APPTCLI, pt)
		if err != nil {
			return fmt.Errorf("unable to get coin home folder: %v", err)
		}
	case PTPIVX:
		abbrev = strings.ToLower(CCoinAbbrevPIVX)
		wl, err = GetCoinHomeFolder(APPTCLI, pt)
		if err != nil {
			return fmt.Errorf("unable to get coin home folder: %v", err)
		}
	case PTRapids:
		abbrev = strings.ToLower(CCoinAbbrevRapids)
		wl, err = GetCoinHomeFolder(APPTCLI, pt)
		if err != nil {
			return fmt.Errorf("unable to get coin home folder: %v", err)
		}
	case PTReddCoin:
		abbrev = strings.ToLower(CCoinAbbrevReddCoin)
		wl, err = GetCoinHomeFolder(APPTCLI, pt)
		if err != nil {
			return fmt.Errorf("unable to get coin home folder: %v", err)
		}
	case PTTrezarcoin:
		abbrev = strings.ToLower(CCoinAbbrevTrezarcoin)
		wl, err = GetCoinHomeFolder(APPTCLI, pt)
		if err != nil {
			return fmt.Errorf("unable to get coin home folder: %v", err)
		}
	case PTVertcoin:
		abbrev = strings.ToLower(CCoinAbbrevVertcoin)
		wl, err = GetCoinHomeFolder(APPTCLI, pt)
		if err != nil {
			return fmt.Errorf("unable to get coin home folder: %v", err)
		}
	default:
		return fmt.Errorf("unable to determine ProjectType - WalletBackup: %v", err)
	}

	// Make sure the coin daemon is not running
	isRunning, _, err := IsCoinDaemonRunning(pt)
	if err != nil {
		return fmt.Errorf("unablle to run IsCoinDaemonRunning: %v", err)
	}
	if isRunning {
		cdn, err := GetCoinDaemonFilename(APPTCLI, pt)
		if err != nil {
			return fmt.Errorf("unablle to run GetCoinDaemonFilename: %v", err)
		}
		return fmt.Errorf("please stop the " + cdn + " daemon first")
	}

	ex, err := os.Executable()
	if err != nil {
		return fmt.Errorf("Unable to retrieve running binary: %v ", err)
	}
	destFolder = AddTrailingSlash(filepath.Dir(ex))

	// Copy the wallet.dat file to the same directory that's running BoxWallet
	if err := BackupFile(wl, "wallet.dat", destFolder, abbrev, true); err != nil {
		return fmt.Errorf("Unable to perform backup of wallet.dat: %v ", err)
	}

	return nil
}

// UnlockWallet - Used by the server to unlock the wallet
//func UnlockWallet(pword string, attempts int, forStaking bool) (bool, error) {
//	var err error
//	var s string = "waiting for wallet."
//	dbf, _ := gwc.GetAppsBinFolder(gwc.APPTServer)
//	app := dbf + gwc.CDiviCliFile
//	arg1 := cCommandUnlockWalletFS
//	arg2 := pword
//	arg3 := "0"
//	arg4 := "true"
//	for i := 0; i < attempts; i++ {
//
//		var cmd *exec.Cmd
//		if forStaking {
//			cmd = exec.Command(app, arg1, arg2, arg3, arg4)
//		} else {
//			cmd = exec.Command(app, arg1, arg2, arg3)
//		}
//		//fmt.Println("cmd = " + dbf + cDiviCliFile + cCommandUnlockWalletFS + `"` + pword + `"` + "0")
//		out, err := cmd.CombinedOutput()
//
//		fmt.Println("string = " + string(out))
//		//fmt.Println("error = " + err.Error())
//
//		if err == nil {
//			return true, err
//		}
//
//		if strings.Contains(string(out), "The wallet passphrase entered was incorrect.") {
//			return false, err
//		}
//
//		if strings.Contains(string(out), "Loading block index....") {
//			//s = s + "."
//			//fmt.Println(s)
//			fmt.Printf("\r"+s+" %d/"+strconv.Itoa(attempts), i+1)
//
//			time.Sleep(3 * time.Second)
//
//		}
//
//	}
//
//	return false, err
//}
