package bend

import (
	"bytes"
	"encoding/json"
	"github.com/dustin/go-humanize"
	"io/ioutil"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const (
	CCoinNamePIVX string = "PIVX"

	CPIVXCoreVersion   string = "5.0.0"
	CDFPIVXFileRPi            = "pivx-" + CPIVXCoreVersion + "-arm-linux-gnueabihf.tar.gz"
	CDFPIVXFileLinux          = "pivx-" + CPIVXCoreVersion + "-x86_64-linux-gnu.tar.gz"
	CDFPIVXFilemacOS          = "pivx-" + CPIVXCoreVersion + "-osx64.tar.gz"
	CDFPIVXFileWindows        = "pivx-" + CPIVXCoreVersion + "-win64.zip"

	// Directory const
	CPIVXExtractedDirArm     string = "pivx-" + CPIVXCoreVersion + "/"
	CPIVXExtractedDirLinux   string = "pivx-" + CPIVXCoreVersion + "/"
	CPIVXExtractedDirWindows string = "pivx-" + CPIVXCoreVersion + "\\"
	CPIVXSaplingDirArm       string = ".pivx-params" + "/"
	CPIVXSaplingDirLinux     string = ".pivx-params" + "/"

	CDownloadURLPIVX string = "https://github.com/PIVX-Project/PIVX/releases/download/v" + CPIVXCoreVersion + "/"

	// PIVX Wallet Constants
	cPIVXHomeDir    string = ".pivx"
	cPIVXHomeDirWin string = "PIVX"

	// File constants
	CPIVXConfFile   string = "pivx.conf"
	CPIVXCliFile    string = "pivx-cli"
	CPIVXCliFileWin string = "pivx-cli.exe"
	CPIVXDFile      string = "pivxd"
	CPIVXDFileWin   string = "pivxd.exe"
	CPIVXTxFile     string = "pivx-tx"
	CPIVXTxFileWin  string = "pivx-tx.exe"

	CPIVXSapling1 string = "sapling-output.params"
	CPIVXSapling2 string = "sapling-spend.params"

	// pivx.conf file constants
	cPIVXRPCUser string = "pivxrpc"
	CPIVXRPCPort string = "51473"
)

type PIVXBlockchainInfoRespStruct struct {
	Result struct {
		Chain                string  `json:"chain"`
		Blocks               int     `json:"blocks"`
		Headers              int     `json:"headers"`
		Bestblockhash        string  `json:"bestblockhash"`
		Difficulty           float64 `json:"difficulty"`
		Verificationprogress float64 `json:"verificationprogress"`
		Chainwork            string  `json:"chainwork"`
		Softforks            []struct {
			ID      string `json:"id"`
			Version int    `json:"version"`
			Reject  struct {
				Status bool `json:"status"`
			} `json:"reject"`
		} `json:"softforks"`
		Upgrades struct {
			PoS struct {
				Activationheight int    `json:"activationheight"`
				Status           string `json:"status"`
				Info             string `json:"info"`
			} `json:"PoS"`
			PoSV2 struct {
				Activationheight int    `json:"activationheight"`
				Status           string `json:"status"`
				Info             string `json:"info"`
			} `json:"PoS v2"`
			Zerocoin struct {
				Activationheight int    `json:"activationheight"`
				Status           string `json:"status"`
				Info             string `json:"info"`
			} `json:"Zerocoin"`
			ZerocoinV2 struct {
				Activationheight int    `json:"activationheight"`
				Status           string `json:"status"`
				Info             string `json:"info"`
			} `json:"Zerocoin v2"`
			BIP65 struct {
				Activationheight int    `json:"activationheight"`
				Status           string `json:"status"`
				Info             string `json:"info"`
			} `json:"BIP65"`
			ZerocoinPublic struct {
				Activationheight int    `json:"activationheight"`
				Status           string `json:"status"`
				Info             string `json:"info"`
			} `json:"Zerocoin Public"`
			PIVXV34 struct {
				Activationheight int    `json:"activationheight"`
				Status           string `json:"status"`
				Info             string `json:"info"`
			} `json:"PIVX v3.4"`
			PIVXV41 struct {
				Activationheight int    `json:"activationheight"`
				Status           string `json:"status"`
				Info             string `json:"info"`
			} `json:"PIVX v4.1"`
		} `json:"upgrades"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type PIVXGetInfoRespStruct struct {
	Result struct {
		Version         int     `json:"version"`
		Protocolversion int     `json:"protocolversion"`
		Services        string  `json:"services"`
		Walletversion   int     `json:"walletversion"`
		Balance         float64 `json:"balance"`
		Zerocoinbalance float64 `json:"zerocoinbalance"`
		StakingStatus   string  `json:"staking status"`
		Blocks          int     `json:"blocks"`
		Timeoffset      int     `json:"timeoffset"`
		Connections     int     `json:"connections"`
		Proxy           string  `json:"proxy"`
		Difficulty      float64 `json:"difficulty"`
		Testnet         bool    `json:"testnet"`
		Moneysupply     float64 `json:"moneysupply"`
		ZPIVsupply      struct {
			Num1    float64 `json:"1"`
			Num5    float64 `json:"5"`
			Num10   float64 `json:"10"`
			Num50   float64 `json:"50"`
			Num100  float64 `json:"100"`
			Num500  float64 `json:"500"`
			Num1000 float64 `json:"1000"`
			Num5000 float64 `json:"5000"`
			Total   float64 `json:"total"`
		} `json:"zPIVsupply"`
		Keypoololdest int     `json:"keypoololdest"`
		Keypoolsize   int     `json:"keypoolsize"`
		UnlockedUntil int     `json:"unlocked_until"`
		Paytxfee      float64 `json:"paytxfee"`
		Relayfee      float64 `json:"relayfee"`
		Errors        string  `json:"errors"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type PIVXGetNewAddressStruct struct {
	Result string      `json:"result"`
	Error  interface{} `json:"error"`
	ID     string      `json:"id"`
}

type PIVXListReceivedByAddressRespStruct struct {
	Result []struct {
		Address         string        `json:"address"`
		Account         string        `json:"account"`
		Amount          float64       `json:"amount"`
		Confirmations   int           `json:"confirmations"`
		Bcconfirmations int           `json:"bcconfirmations"`
		Label           string        `json:"label"`
		Txids           []interface{} `json:"txids"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type PIVXMNSyncStatusRespStruct struct {
	Result struct {
		IsBlockchainSynced         bool `json:"IsBlockchainSynced"`
		LastMasternodeList         int  `json:"lastMasternodeList"`
		LastMasternodeWinner       int  `json:"lastMasternodeWinner"`
		LastBudgetItem             int  `json:"lastBudgetItem"`
		LastFailure                int  `json:"lastFailure"`
		NCountFailures             int  `json:"nCountFailures"`
		SumMasternodeList          int  `json:"sumMasternodeList"`
		SumMasternodeWinner        int  `json:"sumMasternodeWinner"`
		SumBudgetItemProp          int  `json:"sumBudgetItemProp"`
		SumBudgetItemFin           int  `json:"sumBudgetItemFin"`
		CountMasternodeList        int  `json:"countMasternodeList"`
		CountMasternodeWinner      int  `json:"countMasternodeWinner"`
		CountBudgetItemProp        int  `json:"countBudgetItemProp"`
		CountBudgetItemFin         int  `json:"countBudgetItemFin"`
		RequestedMasternodeAssets  int  `json:"RequestedMasternodeAssets"`
		RequestedMasternodeAttempt int  `json:"RequestedMasternodeAttempt"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type PIVXStakingStatusRespStruct struct {
	Result struct {
		StakingStatus       bool    `json:"staking_status"`
		StakingEnabled      bool    `json:"staking_enabled"`
		ColdstakingEnabled  bool    `json:"coldstaking_enabled"`
		Haveconnections     bool    `json:"haveconnections"`
		Mnsync              bool    `json:"mnsync"`
		Walletunlocked      bool    `json:"walletunlocked"`
		Stakeablecoins      int     `json:"stakeablecoins"`
		Stakingbalance      float64 `json:"stakingbalance"`
		Stakesplitthreshold float64 `json:"stakesplitthreshold"`
		LastattemptAge      int     `json:"lastattempt_age"`
		LastattemptDepth    int     `json:"lastattempt_depth"`
		LastattemptHash     string  `json:"lastattempt_hash"`
		LastattemptCoins    int     `json:"lastattempt_coins"`
		LastattemptTries    int     `json:"lastattempt_tries"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type PIVXWalletInfoRespStruct struct {
	Result struct {
		Walletversion              int     `json:"walletversion"`
		Balance                    float64 `json:"balance"`
		DelegatedBalance           float64 `json:"delegated_balance"`
		ColdStakingBalance         float64 `json:"cold_staking_balance"`
		UnconfirmedBalance         float64 `json:"unconfirmed_balance"`
		ImmatureBalance            float64 `json:"immature_balance"`
		ImmatureDelegatedBalance   float64 `json:"immature_delegated_balance"`
		ImmatureColdStakingBalance float64 `json:"immature_cold_staking_balance"`
		Txcount                    int     `json:"txcount"`
		UnlockedUntil              int     `json:"unlocked_until"`
		Keypoololdest              int     `json:"keypoololdest"`
		Keypoolsize                int     `json:"keypoolsize"`
		Hdseedid                   string  `json:"hdseedid"`
		KeypoolsizeHdInternal      int     `json:"keypoolsize_hd_internal"`
		KeypoolsizeHdStaking       int     `json:"keypoolsize_hd_staking"`
		Paytxfee                   float64 `json:"paytxfee"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

func GetBlockchainInfoPIVX(cliConf *ConfStruct) (PIVXBlockchainInfoRespStruct, error) {
	var respStruct PIVXBlockchainInfoRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getblockchaininfo\",\"params\":[]}")
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

func GetBlockchainSyncTxtPIVX(synced bool, bci *PIVXBlockchainInfoRespStruct) string {
	s := ConvertBCVerification(bci.Result.Verificationprogress)
	if s == "0.0" {
		s = ""
	} else {
		s = s + "%"
	}

	if !synced {
		if bci.Result.Verificationprogress > gLastBCSyncPos {
			gLastBCSyncPos = bci.Result.Verificationprogress
			return "Blockchain:  [syncing " + s + " ](fg:yellow)"
		} else {
			gLastBCSyncPos = bci.Result.Verificationprogress
			return "Blockchain:  [waiting " + s + " ](fg:yellow)"
		}
	} else {
		return "Blockchain:  [synced " + CUtfTickBold + "](fg:green)"
	}
}

func GetInfoPIVX(cliConf *ConfStruct) (PIVXGetInfoRespStruct, error) {
	//attempts := 5
	//waitingStr := "Checking server..."

	var respStruct PIVXGetInfoRespStruct

	//lf := "/home/richard/.boxwallet/boxwallet.log"
	for i := 1; i < 50; i++ {
		//fmt.Printf("\r"+waitingStr+" %d/"+strconv.Itoa(attempts), i)
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getinfo\",\"params\":[]}")
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

		// todo remove the below after bug fixed.
		//s := string(bodyResp)
		//AddToLog(lf, s, false)

		// Check to make sure we are not loading the wallet
		if bytes.Contains(bodyResp, []byte("Loading")) || bytes.Contains(bodyResp, []byte("Rewinding")) {
			// The wallet is still loading, so print message, and sleep for 3 seconds and try again..
			var errStruct GenericRespStruct
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

func GetMNSyncStatusPIVX(cliConf *ConfStruct) (PIVXMNSyncStatusRespStruct, error) {
	var respStruct PIVXMNSyncStatusRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"mnsync\",\"params\":[\"status\"]}")
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

func GetMNSyncStatusTxtPIVX(mnss *PIVXMNSyncStatusRespStruct) string {
	if mnss.Result.RequestedMasternodeAssets == 999 {
		return "Masternodes: [synced " + CUtfTickBold + "](fg:green)"
	} else {
		return "Masternodes: [syncing " + getNextProgMNIndicator(gLastMNSyncStatus) + "](fg:yellow)"
	}
}

func GetNetworkBlocksTxtPIVX(bci *PIVXBlockchainInfoRespStruct) string {
	blocksStr := humanize.Comma(int64(bci.Result.Blocks))

	if bci.Result.Blocks > 100 {
		return "Blocks:      [" + blocksStr + "](fg:green)"
	} else {
		return "[Blocks:      " + blocksStr + "](fg:red)"
	}
}

func GetNetworkConnectionsTxtPIVX(connections int) string {
	if connections == 0 {
		return "Peers:       [0](fg:red)"
	}
	return "Peers:       [" + strconv.Itoa(connections) + "](fg:green)"
}

func GetNetworkDifficultyTxtPIVX(difficulty, good, warn float64) string {
	var s string
	if difficulty > 1000 {
		s = humanize.FormatFloat("#.#", difficulty/1000) + "k"
	} else {
		s = humanize.Ftoa(difficulty)
	}
	if difficulty >= good {
		return "Difficulty:  [" + s + "](fg:green)"
	} else if difficulty >= warn {
		return "Difficulty:  [" + s + "](fg:yellow)"
	} else {
		return "Difficulty:  [" + s + "](fg:red)"
	}
}

func GetNewAddressPIVX(cliConf *ConfStruct) (PIVXGetNewAddressStruct, error) {
	var respStruct PIVXGetNewAddressStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getnewaddress\",\"params\":[]}")
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

func GetStakingStatusPIVX(cliConf *ConfStruct) (PIVXStakingStatusRespStruct, error) {
	var respStruct PIVXStakingStatusRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getstakingstatus\",\"params\":[]}")
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

func GetWalletInfoPIVX(cliConf *ConfStruct) (PIVXWalletInfoRespStruct, error) {
	var respStruct PIVXWalletInfoRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"getwalletinfo\",\"params\":[]}")
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

	// Check to see if the json response contains "unlocked_until"
	s := string([]byte(bodyResp))
	if !strings.Contains(s, "unlocked_until") {
		respStruct.Result.UnlockedUntil = -1
	}

	return respStruct, nil
}

func GetWalletSecurityStatePIVX(wi *PIVXWalletInfoRespStruct) WEType {
	if wi.Result.UnlockedUntil == 0 {
		return WETLocked
	} else if wi.Result.UnlockedUntil == -1 {
		return WETUnencrypted
	} else if wi.Result.UnlockedUntil > 0 {
		return WETUnlockedForStaking
	} else {
		return WETUnknown
	}
}

func ListReceivedByAddressPIVX(cliConf *ConfStruct, includeZero bool) (PIVXListReceivedByAddressRespStruct, error) {
	var respStruct PIVXListReceivedByAddressRespStruct

	var s string
	if includeZero {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, true]}"
	} else {
		s = "{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"listreceivedbyaddress\",\"params\":[1, false]}"
	}
	body := strings.NewReader(s)
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

func UnlockWalletPIVX(cliConf *ConfStruct, pw string) error {
	var respStruct GenericRespStruct

	body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"curltext\",\"method\":\"walletpassphrase\",\"params\":[\"" + pw + "\",0]}")
	req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port, body)
	if err != nil {
		return err
	}
	req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
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
