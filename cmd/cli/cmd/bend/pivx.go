package bend

const (
	CCoinNamePIVX string = "PIVX"

	CPIVXCoreVersion   string = "4.3.0"
	CDFPIVXFileRPi            = "pivx-" + CPIVXCoreVersion + "-arm-linux-gnueabihf.tar.gz"
	CDFPIVXFileLinux          = "pivx-" + CPIVXCoreVersion + "-x86_64-linux-gnu.tar.gz"
	CDFPIVXFileWindows        = "pivx-" + CPIVXCoreVersion + "-win64.zip"

	CPIVXExtractedDirArm     string = "pivx-" + CPIVXCoreVersion + "/"
	CPIVXExtractedDirLinux   string = "pivx-" + CPIVXCoreVersion + "/"
	CPIVXExtractedDirWindows string = "pivx-" + CPIVXCoreVersion + "\\"

	CDownloadURLPIVX string = "https://github.com/PIVX-Project/PIVX/releases/download/v" + CPIVXCoreVersion + "/"

	// PIVX Wallet Constants
	cPIVXHomeDir    string = ".pivx"
	cPIVXHomeDirWin string = "PIVX"

	CPIVXConfFile   string = "pivx.conf"
	CPIVXCliFile    string = "pivx-cli"
	CPIVXCliFileWin string = "pivx-cli.exe"
	CPIVXDFile      string = "pivxd"
	CPIVXDFileWin   string = "pivxd.exe"
	CPIVXTxFile     string = "pivx-tx"
	CPIVXTxFileWin  string = "pivx-tx.exe"

	// pivx.conf file constants
	cPIVXRPCUser string = "pivxrpc"
	CPIVXRPCPort string = "51473"
)
