package bend

import (
	"encoding/json"
	"io/ioutil"
	"net/http"
	"strings"
)

const (
	CCoinNameDeVault string = "DeVault"

	CDeVaultCoreVersion string = "1.2.1"

	CDFDeVaultRPi     string = "devault-" + CDeVaultCoreVersion + "-arm64-linuxgnuaarch.tar.gz"
	CDFDeVaultLinux   string = "devault-" + CDeVaultCoreVersion + "-x86_64-linux-gnu.tar.gz"
	CDFDeVaultWindows string = "devault-" + CDeVaultCoreVersion + "-win64.zip"

	//CDeVaultExtractedDirLinux = "linux-x64-" + CDeVaultCoreVersion + "/"
	CDeVaultExtractedDirLinux = "bin/"

	CDownloadURLDeVault string = "https://github.com/devaultcrypto/devault/releases/download/v" + CDeVaultCoreVersion + "/"

	CDeVaultHomeDir    string = ".devault"
	CDeVaultHomeDirWin string = "DEVAULT"

	CDeVaultConfFile   string = "devault.conf"
	CDeVaultCliFile    string = "devault-cli"
	CDeVaultCliFileWin string = "devault-cli.exe"
	CDeVaultDFile      string = "devaultd"
	CDeVaultDFileWin   string = "devaultd.exe"
	CDeVaultTxFile     string = "devault-tx"
	CDeVaultTxFileWin  string = "devault-tx.exe"

	CDeVaultRPCPort string = "3339"
)

// Below may need updating as haven't run it live
type DVTWalletInfoRespStruct struct {
	Result struct {
		Walletname            string  `json:"walletname"`
		Walletversion         int     `json:"walletversion"`
		Balance               float64 `json:"balance"`
		UnconfirmedBalance    float64 `json:"unconfirmed_balance"`
		ImmatureBalance       float64 `json:"immature_balance"`
		Txcount               int     `json:"txcount"`
		Keypoololdest         int     `json:"keypoololdest"`
		Keypoolsize           int     `json:"keypoolsize"`
		Hdseedid              string  `json:"hdseedid"`
		KeypoolsizeHdInternal int     `json:"keypoolsize_hd_internal"`
		Paytxfee              float64 `json:"paytxfee"`
		PrivateKeysEnabled    bool    `json:"private_keys_enabled"`
		AvoidReuse            bool    `json:"avoid_reuse"`
		Scanning              bool    `json:"scanning"`
		UnlockedUntil         int     `json:"unlocked_until"`
	} `json:"result"`
	Error interface{} `json:"error"`
	ID    string      `json:"id"`
}

func GetWalletInfoDVT(cliConf *ConfStruct) (DVTWalletInfoRespStruct, error) {
	var respStruct DVTWalletInfoRespStruct

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
