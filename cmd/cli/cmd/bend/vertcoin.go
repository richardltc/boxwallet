package bend

const (
	CCoinNameVertcoin string = "Vertcoin"

	CVertcoinCoreVersion string = "0.15.0.1"
	//CDFVertcoinRPi       string = "Vertcoin-" + CVertcoinCoreVersion + "-rPI.zip"
	CDFVertcoinLinux   string = "vertcoind-v" + CVertcoinCoreVersion + "-linux-amd64.zip"
	CDFVertcoinWindows string = "vertcoind-v" + CVertcoinCoreVersion + "-win64.zip"

	CVertcoinExtractedDirLinux = "vertcoind-v" + CVertcoinCoreVersion + "-linux-amd64/"

	CDownloadURLVertcoin string = "https://github.com/vertcoin-project/vertcoin-core/releases/download/" + CVertcoinCoreVersion + "/"

	CVertcoinHomeDir    string = ".vertcoin"
	CVertcoinHomeDirWin string = "VERTCOIN"

	CVertcoinConfFile   string = "vertcoin.conf"
	CVertcoinCliFile    string = "vertcoin-cli"
	CVertcoinCliFileWin string = "vertcoin-cli.exe"
	CVertcoinDFile      string = "vertcoind"
	CVertcoinDFileWin   string = "vertcoind.exe"
	CVertcoinTxFile     string = "vertcoin-tx"
	CVertcoinTxFileWin  string = "vertcoin-tx.exe"

	// feathercoin.conf file constants
	CVertcoinRPCPort string = "5888"
)
