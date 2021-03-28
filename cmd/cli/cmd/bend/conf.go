package bend

import (
	"encoding/json"
	"fmt"
	"io/ioutil"
	"log"
	"os"

	//be "richardmace.co.uk/boxwallet/cmd/cli/cmd/bend"
	"runtime"
)

const (
	CConfFile      string = "conf"
	cCoinsConfFile string = "coins.json"
	CConfFileExt   string = ".json"
	cUnknown       string = "Unknown"
)

type ConfStruct struct {
	//BinFolder             string      // The folder that contains the coin binary files
	BlockchainSynced      bool        // If no, don't ask to encrypt wallet within dash command
	Currency              string      // USD, GBP
	FirstTimeRun          bool        // Is this the first time the server has run? If so, we need to store the BinFolder
	PerformHealthCheck    bool        // Should we perform a health check
	LastHealthCheck       string      // When the last health check was run
	RunHealthCheckAt      string      // What time we need to perform a health check
	ProjectType           ProjectType // The project type
	Port                  string      // The port that the server should run on
	RefreshTimer          int         // Refresh interval
	RPCuser               string      // The rpcuser
	RPCpassword           string      // The rpc password
	ServerIP              string      // The IP address of the coin daemon server
	UserConfirmedWalletBU bool        // Whether or not the user has said they've stored their recovery seed has been stored
}

type CoinDetails struct {
	CoinName string
	CoinType ProjectType
	Monitor  bool
}

func AddCoin(confDir string, c CoinDetails) error {
	// If the passed in confDir is blank, then assume current working directory
	if confDir == "" {
		confDir, _ = GetAppWorkingFolder() // os.Getwd()
	}

	confDir = addTrailingSlash(confDir)

	//allcoins := []CoinDetails{}
	allcoins, err := getCoins("")
	if err != nil {
		return err
	}

	//var coin1 = newCoinDetailsStruct()
	//var coin2 = newCoinDetailsStruct()

	// Now make sure that we don't already have the coin.
	bExists := false
	for _, coin := range allcoins {
		if c.CoinType == coin.CoinType {
			bExists = true
		}
	}

	if bExists {
		return nil
	}

	allcoins = append(allcoins, c)

	jssb, err := json.MarshalIndent(allcoins, "", "  ")
	if err != nil {
		return err
	}

	f, err := os.Create(confDir + cCoinsConfFile)
	if err != nil {
		return err
	}

	_, err = f.WriteString(string(jssb))
	err = f.Close()
	if err != nil {
		return err
	}
	return nil
}

func addTrailingSlash(filePath string) string {
	var lastChar = filePath[len(filePath)-1:]
	if runtime.GOOS == "windows" {
		if lastChar == "\\" {
			return filePath
		} else {
			return filePath + "\\"
		}
	} else {
		if lastChar == "/" {
			return filePath
		} else {
			return filePath + "/"
		}
	}
	//return ""
}

func createDefaultConfFile(confDir string) error {
	var conf = newConfStruct()

	jssb, err := json.MarshalIndent(conf, "", "  ")
	if err != nil {
		return err
	}

	f, err := os.Create(confDir + CConfFile + CConfFileExt)
	if err != nil {
		return err
	}

	//log.Println("Creating default conf file " + f.Name())
	_, err = f.WriteString(string(jssb))
	err = f.Close()
	if err != nil {
		return err
	}
	return nil
}

func createDefaultCoinsConfFile(confDir string) error {
	// If the passed in confDir is blank, then assume current working directory
	//dir := ""
	if confDir == "" {
		confDir, _ = GetAppWorkingFolder() // os.Getwd()
	}

	confDir = addTrailingSlash(confDir)

	allcoins := []CoinDetails{}
	var coin1 = newCoinDetailsStruct()
	var coin2 = newCoinDetailsStruct()
	allcoins = append(allcoins, coin1)

	allcoins = append(allcoins, coin2)

	jssb, err := json.MarshalIndent(allcoins, "", "  ")
	if err != nil {
		return err
	}

	f, err := os.Create(confDir + cCoinsConfFile)
	if err != nil {
		return err
	}

	log.Println("Creating dummy conf file " + f.Name())
	_, err = f.WriteString(string(jssb))
	err = f.Close()
	if err != nil {
		return err
	}
	return nil
}

// GetConfigStruct
func GetConfigStruct(confDir string, refreshFields bool) (ConfStruct, error) {
	// If the passed in confDir is blank, then assume current working directory
	//dir := ""
	if confDir == "" {
		confDir, _ = GetAppWorkingFolder()
	}

	confDir = addTrailingSlash(confDir)

	// Create the file if it doesn't already exist
	if _, err := os.Stat(confDir + CConfFile + CConfFileExt); os.IsNotExist(err) {
		if err := createDefaultConfFile(confDir); err != nil {
			return ConfStruct{}, err
		}
	}

	// Get the config file
	file, err := ioutil.ReadFile(confDir + CConfFile + CConfFileExt)
	if err != nil {
		return ConfStruct{}, err
	}

	cs := ConfStruct{}

	err = json.Unmarshal([]byte(file), &cs)
	if err != nil {
		return ConfStruct{}, err
	}

	// Now, let's write the file back because it may have some new fields
	if refreshFields {
		if err := SetConfigStruct(confDir, cs); err != nil {
			return ConfStruct{}, err
		}
	}

	return cs, nil
}

func getCoins(dir string) ([]CoinDetails, error) {
	//// Create the file if it doesn't already exist
	//dir, _ = addTrailingSlash(dir)
	//if _, err := os.Stat(dir + cDbConfFile); os.IsNotExist(err) {
	//	if err := createDummyDBConfFile(dir); err != nil {
	//		return nil, fmt.Errorf("unable to create dummy db conf file: %v", err)
	//	}
	//	// We need to quit the app now, as the user needs to complete the db-conf files
	//	return nil, errors.New("new " + cDbConfFile + " created, which needs to be populated before we go further")
	//}
	coinsd := []CoinDetails{}

	if dir == "" {
		dir, _ = GetAppWorkingFolder()
	}

	if !FileExists(dir + cCoinsConfFile) {
		return coinsd, nil
	}
	file, err := ioutil.ReadFile(dir + cCoinsConfFile)
	if err != nil {
		return coinsd, err
	}

	err = json.Unmarshal([]byte(file), &coinsd)
	if err != nil {
		return coinsd, err
	}

	// Now, let's write the file back because it may have some new fields
	if err := setCoins(dir, coinsd); err != nil {
		return nil, fmt.Errorf("unable to write coinsdb: %v", err)
	}

	return coinsd, nil
}

func newConfStruct() ConfStruct {
	cnf := ConfStruct{}
	//cnf.BinFolder = ""
	cnf.BlockchainSynced = false
	cnf.Currency = "USD"
	cnf.FirstTimeRun = true
	cnf.ProjectType = 0
	cnf.PerformHealthCheck = false
	cnf.LastHealthCheck = cUnknown
	cnf.RunHealthCheckAt = "01:15"
	cnf.RefreshTimer = 3
	cnf.RPCuser = ""
	cnf.RPCpassword = ""
	cnf.ServerIP = "127.0.0.1"
	cnf.Port = ""
	cnf.UserConfirmedWalletBU = false

	return cnf
}

func newCoinDetailsStruct() CoinDetails {
	coind := CoinDetails{}
	coind.CoinName = "DIVI"
	coind.CoinType = 0
	coind.Monitor = false

	return coind
}

func setCoins(dir string, dbd []CoinDetails) error {
	if dir == "" {
		dir, _ = GetAppWorkingFolder()
	}

	jssb, _ := json.MarshalIndent(dbd, "", "  ")
	dir = AddTrailingSlash(dir)
	sFile := dir + cCoinsConfFile

	f, err := os.Create(sFile)
	if err != nil {
		return err
	}

	_, err = f.WriteString(string(jssb))
	err = f.Close()
	if err != nil {
		return err
	}
	return nil
}

func SetConfigStruct(confDir string, cs ConfStruct) error {
	if confDir == "" {
		confDir, _ = GetAppWorkingFolder()
	}

	jssb, _ := json.MarshalIndent(cs, "", "  ")
	confDir = addTrailingSlash(confDir)
	sFile := confDir + CConfFile + CConfFileExt

	f, err := os.Create(sFile)
	if err != nil {
		return err
	}

	_, err = f.WriteString(string(jssb))
	err = f.Close()
	if err != nil {
		return err
	}
	return nil
}
