package bend

const (
	CCoinNameDivi string = "Divi"

	// CDiviAppVersion - The app version of Divi
	//CDiviAppVersion string = "1.1.2"
	CDiviHomeDir    string = ".divi"
	CDiviHomeDirWin string = "DIVI"

	CDiviCoreVersion string = "1.1.2"
	CDFDiviRPi              = "divi-" + CDiviCoreVersion + "-RPi2.tar.gz"
	CDFDiviLinux            = "divi-" + CDiviCoreVersion + "-x86_64-linux-gnu.tar.gz"
	CDFDiviWindows          = "divi-" + CDiviCoreVersion + "-win64.zip"

	CDiviExtractedDir = "divi-" + CDiviCoreVersion + "/"

	CDownloadURLDivi = "https://github.com/DiviProject/Divi/releases/download/v" + CDiviCoreVersion + "/"

	CDiviConfFile   string = "divi.conf"
	CDiviCliFile    string = "divi-cli"
	CDiviCliFileWin string = "divi-cli.exe"
	CDiviDFile      string = "divid"
	CDiviDFileWin   string = "divid.exe"
	CDiviTxFile     string = "divi-tx"
	CDiviTxFileWin  string = "divi-tx.exe"
)
