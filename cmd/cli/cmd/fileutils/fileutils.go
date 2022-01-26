package fileutils

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"io/ioutil"
	"os"
	"runtime"
	"strings"
	"time"
)

func AddTrailingSlash(filePath string) string {
	var lastChar = filePath[len(filePath)-1:]
	switch runtime.GOOS {
	case "windows":
		if lastChar == "\\" {
			return filePath
		} else {
			return filePath + "\\"
		}
	case "linux":
		if lastChar == "/" {
			return filePath
		} else {
			return filePath + "/"
		}
	}

	return ""
}

func BackupFile(srcFolder, srcFile, dstFolder, prefixStr string, failOnNoSrc bool) error {
	dt := time.Now()
	dtStr := dt.Format("2006-01-02")

	if !FileExists(srcFolder + srcFile) {
		if failOnNoSrc {
			return errors.New(srcFolder + srcFile + " doesn't exist")
		} else {
			return nil
		}
	}

	originalFile, err := os.Open(srcFolder + srcFile)
	if err != nil {
		return err
	}
	defer originalFile.Close()

	if dstFolder == "" {
		dstFolder = srcFolder
	}

	var s string
	if prefixStr != "" {
		s = prefixStr + "-"
	}

	newFile, err := os.Create(dstFolder + s + dtStr + "-" + srcFile)
	if err != nil {
		return err
	}
	defer newFile.Close()

	_, err = io.Copy(newFile, originalFile)
	if err != nil {
		return err
	}

	err = newFile.Sync()
	if err != nil {
		return err
	}

	return nil
}

func GetStrAfterStr(value string, a string) string {
	// Get substring after a string.
	pos := strings.LastIndex(value, a)
	if pos == -1 {
		return ""
	}
	adjustedPos := pos + len(a)
	if adjustedPos >= len(value) {
		return ""
	}
	return value[adjustedPos:]
}

// GetStringAfterStrFromFile - Returns the string after the passed string: e.g line in file is "greeting=hi", if the stringToFind was "greeting=" it would return "hi""
func GetStringAfterStrFromFile(stringToFind, file string) (string, error) {
	if !FileExists(file) {
		return "", nil
	}

	data, err := ioutil.ReadFile(file)
	if err != nil {
		return "", err
	}
	scanner := bufio.NewScanner(strings.NewReader(string(data)))
	for scanner.Scan() {
		s := scanner.Text()
		if strings.Contains(s, stringToFind) {
			t := GetStrAfterStr(s, "=") //strings.Replace(s,stringToFind,"", -1)
			return t, nil
		}
	}

	return "", nil
}

func FileCopy(srcFile, destFile string, dispOutput bool) error {
	// Open original file
	originalFile, err := os.Open(srcFile)
	if err != nil {
		return err
	}
	defer originalFile.Close()

	// Create new file
	newFile, err := os.Create(destFile)
	if err != nil {
		return err
	}
	defer newFile.Close()

	// Copy the bytes to destination from source
	bytesWritten, err := io.Copy(newFile, originalFile)
	if err != nil {
		return err
	}
	if dispOutput {
		fmt.Printf("Copied %d bytes.", bytesWritten)
	}

	// Commit the file contents
	// Flushes memory to disk
	err = newFile.Sync()
	if err != nil {
		return err
	}

	return nil
}

func FileExists(filename string) bool {
	info, err := os.Stat(filename)
	if os.IsNotExist(err) {
		return false
	}
	return !info.IsDir()
}

func StringExistsInFile(str, file string) (bool, error) {
	if !FileExists(file) {
		return false, errors.New("unable to find the file: " + file)
	}

	data, err := ioutil.ReadFile(file)
	if err != nil {
		return false, errors.New(err.Error())
	}
	scanner := bufio.NewScanner(strings.NewReader(string(data)))
	for scanner.Scan() {
		s := scanner.Text()
		if strings.Contains(s, str) {
			return true, nil
		}
	}
	return false, nil
}

func WriteTextToFile(fileName, text string) error {
	// Open a new file for writing only
	file, err := os.OpenFile(
		fileName,
		os.O_WRONLY|os.O_APPEND|os.O_CREATE,
		0666,
	)
	if err != nil {
		return err
	}
	defer file.Close()

	byteSlice := []byte(text + "\n")
	_, err = file.Write(byteSlice)
	if err != nil {
		return err
	}

	return nil
}
