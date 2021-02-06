package bend

import (
	"bytes"
	"encoding/json"
	"github.com/dustin/go-humanize"
	"github.com/theckman/yacspin"
	"io/ioutil"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const (
	CCoinNameRapids   string = "Rapids"
	CCoinAbbrevRapids string = "RPD"

	CRapidsCoreVersion string = "3.4.1"

	//CDFRapidsFileRPi   string = "rapids-" + CRapidsCoreVersion + "-arm64.tar.gz"
	CDFRapidsFileLinux   string = "rapids-" + CRapidsCoreVersion + "-lin64.tgz"
	CDFRapidsFileWindows string = "rapids-" + CRapidsCoreVersion + "-win64.zip"

	CRapidsExtractedDirLinux = "rapids-lin64" + "/"
	//CRapidsExtractedDirDaemon  = "Rapids-" + CRapidsCoreVersion + "-daemon-ubuntu1804" + "/"
	CRapidsExtractedDirWindows = "rapids-3.4.1-win64" + "\\"

	//https://github.com/RapidsOfficial/Rapids/releases/download/aa4e5a8/rapids-3.4.1-lin64.tgz
	CDownloadURLRapids string = "https://github.com/RapidsOfficial/Rapids/releases/download/aa4e5a8/"

	cRapidsHomeDir    string = ".rapids"
	cRapidsHomeDirWin string = "RAPIDS"

	CRapidsConfFile   string = "rapids.conf"
	CRapidsCliFile    string = "rapids-cli"
	CRapidsCliFileWin string = "rapids-cli.exe"
	CRapidsDFile      string = "rapidsd"
	CRapidsDFileWin   string = "rapidsd.exe"
	CRapidsTxFile     string = "rapids-tx"
	CRapidsTxFileWin  string = "rapids-tx.exe"

	cRapidsRPCUser string = "rapidsrpc"
	CRapidsRPCPort string = "28732"
)

type RapidsBlockchainInfoRespStruct struct {
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
				Activationheight int64  `json:"activationheight"`
				Status           string `json:"status"`
				Info             string `json:"info"`
			} `json:"Zerocoin"`
			ZerocoinV2 struct {
				Activationheight int64  `json:"activationheight"`
				Status           string `json:"status"`
				Info             string `json:"info"`
			} `json:"Zerocoin v2"`
			BIP65 struct {
				Activationheight int    `json:"activationheight"`
				Status           string `json:"status"`
				Info             string `json:"info"`
			} `json:"BIP65"`
			ZerocoinPublic struct {
				Activationheight int64  `json:"activationheight"`
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

type RapidsGetInfoRespStruct struct {
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
		Paytxfee      float64 `json:"paytxfee"`
		Relayfee      float64 `json:"relayfee"`
		Errors        string  `json:"errors"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

type RapidsListReceivedByAddressRespStruct struct {
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

type RapidsMNSyncStatusRespStruct struct {
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

type RapidsStakingStatusRespStruct struct {
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

type RapidsWalletInfoRespStruct struct {
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

func getRapidsAddNodes() ([]byte, error) {
	addnodes := []byte("addnode=104.248.62.138:28732\n" +
		"addnode=108.61.189.250:58678\n" +
		"addnode=138.197.145.38:28732\n" +
		"addnode=142.93.157.62:55586\n" +
		"addnode=144.91.117.147:28732\n" +
		"addnode=145.239.64.148:28732\n" +
		"addnode=159.203.22.189:33890\n" +
		"addnode=159.89.94.245:28732\n" +
		"addnode=162.157.204.186:50753\n" +
		"addnode=165.22.104.43:46592")

	return addnodes, nil
}

func GetBlockchainInfoRapids(cliConf *ConfStruct) (RapidsBlockchainInfoRespStruct, error) {
	var respStruct RapidsBlockchainInfoRespStruct

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

func GetInfoRapids(cliConf *ConfStruct) (RapidsGetInfoRespStruct, error) {
	//attempts := 5
	//waitingStr := "Checking server..."

	var respStruct RapidsGetInfoRespStruct

	for i := 1; i < 50; i++ {
		//fmt.Printf("\r"+waitingStr+" %d/"+strconv.Itoa(attempts), i)
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandGetInfo + "\",\"params\":[]}")
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

		// Check to make sure we are not loading the wallet
		if bytes.Contains(bodyResp, []byte("Loading")) ||
			bytes.Contains(bodyResp, []byte("Rewinding")) ||
			bytes.Contains(bodyResp, []byte("Verifying")) {
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

func GetInfoRPDUI(cliConf *ConfStruct, spin *yacspin.Spinner) (RapidsGetInfoRespStruct, string, error) {
	var respStruct RapidsGetInfoRespStruct

	for i := 1; i < 600; i++ {
		body := strings.NewReader("{\"jsonrpc\":\"1.0\",\"id\":\"boxwallet\",\"method\":\"" + cCommandGetInfo + "\",\"params\":[]}")
		req, err := http.NewRequest("POST", "http://"+cliConf.ServerIP+":"+cliConf.Port, body)
		if err != nil {
			return respStruct, "", err
		}
		req.SetBasicAuth(cliConf.RPCuser, cliConf.RPCpassword)
		req.Header.Set("Content-Type", "text/plain;")

		for j := 1; j < 60; j++ {
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				spin.Message(" waiting for your " + CCoinNameRapids + " wallet to respond, this could take several minutes (ctrl-c to cancel)...")
				time.Sleep(1 * time.Second)
				continue
			}
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
				var errStruct GenericRespStruct
				err = json.Unmarshal(bodyResp, &errStruct)
				if err != nil {
					return respStruct, "", err
				}

				if bytes.Contains(bodyResp, []byte("Loading")) {
					spin.Message(" Your " + CCoinNameRapids + " wallet is currently Loading, this could take several minutes...")
				} else if bytes.Contains(bodyResp, []byte("Rescanning")) {
					spin.Message(" Your " + CCoinNameRapids + " wallet is currently Rescanning, this could take several minutes...")
				} else if bytes.Contains(bodyResp, []byte("Rewinding")) {
					spin.Message(" Your " + CCoinNameRapids + " wallet is currently Rewinding, this could take several minutes...")
				} else if bytes.Contains(bodyResp, []byte("Verifying")) {
					spin.Message(" Your " + CCoinNameRapids + " wallet is currently Verifying, this could take several minutes...")
				} else if bytes.Contains(bodyResp, []byte("Calculating money supply")) {
					spin.Message(" Your " + CCoinNameRapids + " wallet is currently Calculating money supply, this could take several minutes...")
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

func GetMNSyncStatusRapids(cliConf *ConfStruct) (RapidsMNSyncStatusRespStruct, error) {
	var respStruct RapidsMNSyncStatusRespStruct

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

func GetNetworkBlocksTxtRapids(bci *RapidsBlockchainInfoRespStruct) string {
	blocksStr := humanize.Comma(int64(bci.Result.Blocks))

	if bci.Result.Blocks > 100 {
		return "Blocks:      [" + blocksStr + "](fg:green)"
	} else {
		return "[Blocks:      " + blocksStr + "](fg:red)"
	}
}

func GetNetworkConnectionsTxtRPD(connections int) string {
	if connections == 0 {
		return "Peers:       [0](fg:red)"
	}
	return "Peers:       [" + strconv.Itoa(connections) + "](fg:green)"
}

func GetNetworkDifficultyTxtRapids(difficulty, good, warn float64) string {
	var s string
	if difficulty > 1000 {
		s = humanize.FormatFloat("#.#", difficulty/1000) + "k"
	} else {
		s = humanize.Ftoa(difficulty)
	}
	if difficulty >= good {
		return "Difficulty:  [" + s + "](fg:green)"
	} else if difficulty >= warn {
		return "[Difficulty:  " + s + "](fg:yellow)"
	} else {
		return "[Difficulty:  " + s + "](fg:red)"
	}
}

func GetBlockchainSyncTxtRapids(synced bool, bci *RapidsBlockchainInfoRespStruct) string {
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

func GetMNSyncStatusTxtRapids(mnss *RapidsMNSyncStatusRespStruct) string {
	if mnss.Result.RequestedMasternodeAssets == 999 {
		return "Masternodes: [synced " + CUtfTickBold + "](fg:green)"
	} else {
		return "Masternodes: [syncing " + getNextProgMNIndicator(gLastMNSyncStatus) + "](fg:yellow)"
	}
}

func GetStakingStatusRapids(cliConf *ConfStruct) (RapidsStakingStatusRespStruct, error) {
	var respStruct RapidsStakingStatusRespStruct

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

func GetWalletInfoRapids(cliConf *ConfStruct) (RapidsWalletInfoRespStruct, error) {
	var respStruct RapidsWalletInfoRespStruct

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

func GetWalletSecurityStateRapids(wi *RapidsWalletInfoRespStruct) WEType {
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

func ListReceivedByAddressRapids(cliConf *ConfStruct, includeZero bool) (RapidsListReceivedByAddressRespStruct, error) {
	var respStruct RapidsListReceivedByAddressRespStruct

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

func UnlockWalletRapids(cliConf *ConfStruct, pw string) error {
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
