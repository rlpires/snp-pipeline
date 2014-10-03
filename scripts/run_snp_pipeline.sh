#!/bin/bash
#
#Author: Steve Davis (scd)
#Purpose: 
#    Run the SNP Pipeline on a specified data set.
#Input:
#    reference          : fasta genome reference file
#    samples            : collection of samples, each in a separate directory
#    workDirectory      : directory where the data is copied and results will be generated
#
#    This script expects the following directories and files:
#    <reference name>.fasta
#    <multiple sample subdirectories>/*.fastq
#Output:
#	 If requested, this script mirrors the reference and samples into a new 
#    <workDirectory>.  Within the <workDirectory>, the input files are
#    linked and the outputs are generated.  Many files are generated, but the 
#    most important results are:
#        <workDirectory>/snplist.txt
#            a SNP list identifying the SNPs found across all samples
#        <workDirectory>/snpma.fasta
#            a SNP matrix with one row per sample and one column per SNP
#        <workDirectory>/samples/<multiple sample subdirectories>/reads.snp.pileup
#            one pileup file per sample
#        <workDirectory>/referenceSNP.fasta
#            a fasta file containing the reference sequence bases at all the SNP locations
#Use example:
#
#History:
#   20140910-scd: Started.
#Notes:
#
#Bugs:
#

# Exit on error
set -e

usage()
{
    echo "usage: run_snp_pipeline.sh [-h] [-f] [-m] [-c|-C FILE] [-Q \"torque\"]  -o DIR  (-s DIR | -S FILE)  referenceFile"
    echo
    echo 'Run the SNP Pipeline on a specified data set.'
    echo
    echo 'Positional arguments:'
    echo '  referenceFile    : Relative or absolute path to the reference fasta file.'
    echo
    echo 'Options:'
    echo '  -h               : Show this help message and exit.'
    echo
    echo '  -f               : Force processing even when result files already exist and are newer than inputs.'
    echo
    echo '  -m               : Create a mirror copy of the reference directory and all the sample directories.'
    echo '                     Use this option to avoid polluting reference directory and sample directories '
    echo '                     with the intermediate files generated by the snp pipeline.  A "reference" '
    echo '                     subdirectory and a "samples" subdirectory are created under the output directory'
    echo '                     (see the -o option).  One directory per sample is created under the "samples" '
    echo '                     directory.  Soft links to the fasta and fastq files are created in the'
    echo '                     mirrored directories so the copy is fast and storage space is conserved.'
    echo
    echo '  -c FILE          : TODO - NOT IMPLEMENTED YET.'
    echo '                     Configuration file for overriding default parameters and defining extra '
    echo '                     parameters for the tools and scripts within the pipeline.  If the file does '
    echo '                     not exist, it is created with default parameter values and this script will '
    echo '                     immediately exit.'
    echo 
    echo '  -Q "torque"      : Job queue manager for remote parallel job execution in an HPC environment.'
    echo '                     Currently only "torque" is supported.  If not specified, the pipeline will'
    echo '                     execute locally.'
    echo
    echo '  -o DIR           : Output directory for the snp list, snp matrix, and reference snp files. '
    echo '                     Additional subdirectories are automatically created under the output directory'
    echo '                     for logs files and the mirrored samples and reference files (see the -m option).'
    echo '                     The output directory will be created if it does not already exist.  If not '
    echo '                     specified, the output files are written to the current working directory.'
    echo
    echo '  -s DIRECTORY     : Relative or absolute path to the parent directory of all the sample directories.'
    echo '                     The -s option should be used when all the sample directories are in'
    echo '                     subdirectories immediately below a parent directory.'
    echo '                     Note: You must specify either the -s or -S option, but not both.'
    echo '                     Note: The specified directory should contain only a collection of sample'
    echo '                           directories, nothing else.'
    echo '                     Note: Additional files will be written to each of the sample directories'
    echo '                           during the execution of the SNP Pipeline'
    echo 
    echo '  -S FILE          : Relative or absolute path to a file listing all of the sample directories.'
    echo '                     The -S option should be used when the samples are not under a common parent '
    echo '                     directory.  '
    echo '                     Note: If you are not mirroring the samples (see the -m option), you can'
    echo '                           improve parallel processing performance by sorting the the list of '
    echo '                           directories descending by size, largest first.  The -m option '
    echo '                           automatically generates a sorted directory list.'
    echo '                     Note: You must specify either the -s or -S option, but not both.'
    echo '                     Note: Additional files will be written to each of the sample directories'
    echo '                           during the execution of the SNP Pipeline'
    echo
}

get_abs_filename() 
{
  # $1 : relative filename
  echo "$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
}

# --------------------------------------------------------
# getopts command line option handler: 

# For each valid option, 
#   If it is given, create a var dynamically to
#   indicate it is set: $opt_name_set = 1

#   If var gets an arg, create another var to
#   hold its value: $opt_name_arg = some value

# For invalid options given, 
#   Invoke Usage routine

# precede option list with a colon
# option list is a list of allowed option characters
# options that require an arg are followed by a colon

# example: ":abc:d"
# -abc 14 -d

echo
while getopts ":hfmc:Q:o:s:S:" option; do
    if [ "$option" = "h" ]; then
        usage
        exit 0
    elif [ "$option" = "?" ]; then
        echo "Invalid option -- '$OPTARG'"
        echo
        usage
        exit 1
    elif [ "$option" = ":" ]; then
        echo "Missing argument for option -- '$OPTARG'"
        echo
        usage
        exit 2
    else
        declare opt_"$option"_set="1"
        if [ "$OPTARG" != "" ]; then
            declare opt_"$option"_arg="$OPTARG"
        fi
    fi
done

# --------------------------------------------------------
# get the arguments
shift $((OPTIND-1))

# Reference fasta file
export referenceFilePath="$1"
if [ "$referenceFilePath" = "" ]; then
    echo "Missing reference file."
    echo
    usage
    exit 3
fi
if [[ ! -f "$referenceFilePath" ]]; then echo "Reference file $referenceFilePath does not exist."; exit 3; fi
if [[ ! -s "$referenceFilePath" ]]; then echo "Reference file $referenceFilePath is empty."; exit 3; fi

# Extra arguments not allowed
if [[ "$2" != "" ]]; then 
    echo "Unexpected argument \"$2\" specified after the reference file."
    echo
    usage
    exit 100
fi

# Force rebuild flag
if [[ "$opt_f_set" = "1" ]]; then
    export forceFlag="-f"
else
    unset forceFlag
fi

# Mirror copy input files flag
if [[ "$opt_m_set" = "1" ]]; then
    mirrorFlag="1"
else
    unset mirrorFlag
fi

# Job queue manager for remote parallel job execution
if [[ "$opt_Q_set" = "1" ]]; then
    platform=$(echo "$opt_Q_arg" | tr '[:upper:]' '[:lower:]')
    if [[ "$platform" != "torque" ]]; then
        echo "Only the torque job queue is currently supported."
        echo
        usage
        exit 4
    fi
fi

# Handle output working directory.  Create the directory if it does not exist.
if [[ "$opt_o_set" = "1" ]]; then
    export workDir="$opt_o_arg"
    if ! mkdir -p "$workDir"; then echo "Could not create the output directory $workDir"; exit 5; fi
    if [[ ! -w "$workDir" ]]; then echo "Output directory $workDir is not writable."; exit 5; fi
else
    export workDir="$(pwd)"
fi

# Handle sample directories
if [[ "$opt_s_set" = "1" && "$opt_S_set" = "1" ]]; then
    echo "Options -s and -S are mutually exclusive."
    echo
    usage
    exit 6
fi
if [[ "$opt_s_set" != "1" && "$opt_S_set" != "1" ]]; then
    echo "You must specify one of the -s or -S options to identify the samples."
    echo
    usage
    exit 6
fi

# --------------------------------------------------------
# get sample directories sorted by size, largest first
if [[ "$opt_s_set" = "1" ]]; then
    samplesDir="$opt_s_arg"
    if [[ ! -d "$samplesDir" ]]; then echo "Samples directory $samplesDir does not exist."; exit 6; fi
    ls -d "$samplesDir"/* | sed 's/.*/"&"/' | xargs ls -L -s -m | grep -E "($samplesDir|total)" | sed 'N;s/\n//;s/:total//' | sort -k 2 -n -r | sed 's/ \w*$//' > "$workDir/sampleDirectories.txt"
    sampleDirsFile="$workDir/sampleDirectories.txt"
fi
if [[ "$opt_S_set" = "1" ]]; then
    sampleDirsFile="$opt_S_arg"
    if [[ ! -f "$sampleDirsFile" ]]; then echo "The file of samples directories, $sampleDirsFile, does not exist."; exit 6; fi
    if [[ ! -s "$sampleDirsFile" ]]; then echo "The file of samples directories, $sampleDirsFile, is empty."; exit 6; fi
fi
sampleCount=$(cat "$sampleDirsFile" | wc -l)

# --------------------------------------------------------
# Mirror the input reference and samples if requested
if [[ "$mirrorFlag" = "1" ]]; then
    # Mirror/link the reference
    mkdir -p "$workDir/reference"
    absoluteReferenceFilePath=$(get_abs_filename "$referenceFilePath")
    cp -v -u -s "$absoluteReferenceFilePath" "$workDir/reference"
    # since we mirrored the reference, we need to update our reference location
    referenceFileName=${referenceFilePath##*/} # strip directories
    referenceFilePath="$workDir/reference/$referenceFileName"

    # Mirror/link the samples
    cat "$sampleDirsFile" | while read dir
    do
        baseDir=${dir##*/} # strip the parent directories
        mkdir -p "$workDir/samples/$baseDir"
        # copy without stderr message and without exit error code
        absoluteSampleDir=$(get_abs_filename "$dir")
        cp -v -r -s -u "$absoluteSampleDir"/*.fastq* "$workDir/samples/$baseDir" 2> /dev/null || true
        cp -v -r -s -u "$absoluteSampleDir"/*.fq* "$workDir/samples/$baseDir" 2> /dev/null || true
    done
    # since we mirrored the samples, we need to update our samples location and sorted list of samples
    samplesDir="$workDir/samples"
    ls -d "$samplesDir"/* | sed 's/.*/"&"/' | xargs ls -L -s -m | grep -E "($samplesDir|total)" | sed 'N;s/\n//;s/:total//' | sort -k 2 -n -r | sed 's/ \w*$//' > "$workDir/sampleDirectories.txt"
    sampleDirsFile="$workDir/sampleDirectories.txt"
fi

# Create the logs directory
runTimeStamp=$(date +"%Y%m%d.%H%M%S")
export logDir="$workDir/logs-$runTimeStamp"
mkdir -p "$logDir"


# --------------------------------------------------------
# TODO : Check for fresh files and skip processing unless force flag is set
# TODO : create -c file with default parameters
# TODO : execute -c file to get parameters
# TODO : change scripts to use -c parameters
# TODO : workstation logging

# --------------------------------------------------------
echo -e "\nStep 1 - Prep work"
export numCores=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || sysctl -n hw.ncpu)
# get the *.fastq or *.fq files in each sample directory, possibly compresessed, on one line per sample, ready to feed to bowtie
tmpFile=$(mktemp -p "$workDir" tmp.fastqs.XXXXXXXX)
cat "$sampleDirsFile" | while read dir; do echo $dir/*.fastq* >> "$tmpFile"; echo "$dir"/*.fq* >> "$tmpFile"; done
grep -v '*.fq*' "$tmpFile" | grep -v '*.fastq*' > "$workDir/sampleFullPathNames.txt"
rm "$tmpFile"

echo -e "\nStep 2 - Prep the reference"
if [[ "$platform" == "torque" ]]; then
    prepReferenceJobId=$(echo | qsub << _EOF_
    #PBS -N job.prepReference
    #PBS -j oe
    #PBS -d $(pwd)
    #PBS -o $logDir/prepReference.log
    prepReference.sh $forceFlag "$referenceFilePath" 
_EOF_
)
else
    prepReference.sh $forceFlag "$referenceFilePath" 2>&1 | tee $logDir/prepReference.log
fi

echo -e "\nStep 3 - Align the samples to the reference"
if [[ "$platform" == "torque" ]]; then
    numAlignThreads=8
    alignSamplesJobId=$(echo | qsub -t 1-$sampleCount << _EOF_
    #PBS -N job.alignSamples
    #PBS -d $(pwd)
    #PBS -j oe
    #PBS -l nodes=1:ppn=$numAlignThreads
    #PBS -W depend=afterok:$prepReferenceJobId
    #PBS -o $logDir/alignSamples.log
    samplesToAlign=\$(cat "$workDir/sampleFullPathNames.txt" | head -n \$PBS_ARRAYID | tail -n 1)
    alignSampleToReference.sh $forceFlag -p $numAlignThreads "$referenceFilePath" \$samplesToAlign
_EOF_
)
else
    nl "$workDir/sampleFullPathNames.txt" | xargs -n 3 -L 1 sh -c 'alignSampleToReference.sh $forceFlag -p $numCores "$referenceFilePath" $1 $2 2>&1 | tee $logDir/alignSamples.log-$0'
fi

echo -e "\nStep 4 - Prep the samples"
if [[ "$platform" == "torque" ]]; then
    sleep 2 # workaround torque bug when submitting two large consecutive array jobs
    alignSamplesJobArray=${alignSamplesJobId%%.*}
    prepSamplesJobId=$(echo | qsub -t 1-$sampleCount << _EOF_
    #PBS -N job.prepSamples
    #PBS -d $(pwd)
    #PBS -j oe
    #PBS -W depend=afterokarray:$alignSamplesJobArray
    #PBS -l walltime=05:00:00
    #PBS -o $logDir/prepSamples.log
    sampleDir=\$(cat "$sampleDirsFile" | head -n \$PBS_ARRAYID | tail -n 1)
    prepSamples.sh $forceFlag "$referenceFilePath" "\$sampleDir"
_EOF_
)
else
    nl "$sampleDirsFile" | xargs -n 2 -P $numCores sh -c 'prepSamples.sh $forceFlag "$referenceFilePath" $1 2>&1 | tee $logDir/prepSamples.log-$0'
fi

echo -e "\nStep 5 - Combine the SNP positions across all samples into the SNP list file"
if [[ "$platform" == "torque" ]]; then
    prepSamplesJobArray=${prepSamplesJobId%%.*}
    snpListJobId=$(echo | qsub << _EOF_
    #PBS -N job.snpList
    #PBS -d $(pwd)
    #PBS -j oe
    #PBS -W depend=afterokarray:$prepSamplesJobArray
    #PBS -o $logDir/snpList.log
    create_snp_list.py -n var.flt.vcf -o "$workDir/snplist.txt" "$sampleDirsFile" 
_EOF_
)
else
    create_snp_list.py -n var.flt.vcf -o "$workDir/snplist.txt" "$sampleDirsFile" 2>&1 | tee $logDir/snpList.log
fi

echo -e "\nStep 6 - Create pileups at SNP positions for each sample"
if [[ "$platform" == "torque" ]]; then
    snpPileupJobId=$(echo | qsub -t 1-$sampleCount << _EOF_
    #PBS -N job.snpPileup
    #PBS -d $(pwd)
    #PBS -j oe
    #PBS -W depend=afterok:$snpListJobId
    #PBS -o $logDir/snpPileup.log
    sampleDir=\$(cat "$sampleDirsFile" | head -n \$PBS_ARRAYID | tail -n 1)
    create_snp_pileup.py -l "$workDir/snplist.txt" -a "\$sampleDir/reads.all.pileup" -o "\$sampleDir/reads.snp.pileup"
_EOF_
)
else
    nl "$sampleDirsFile" | xargs -n 2 -P $numCores sh -c 'create_snp_pileup.py -l "$workDir/snplist.txt" -a "$1/reads.all.pileup" -o "$1/reads.snp.pileup" 2>&1 | tee $logDir/snpPileup.log-$0'
fi

echo -e "\nStep 7 - Create the SNP matrix"
if [[ "$platform" == "torque" ]]; then
    snpPileupJobArray=${snpPileupJobId%%.*}
    snpMatrixJobId=$(echo | qsub << _EOF_
    #PBS -N job.snpMatrix
    #PBS -d $(pwd)
    #PBS -j oe
    #PBS -W depend=afterokarray:$snpPileupJobArray
    #PBS -l walltime=05:00:00
    #PBS -o $logDir/snpMatrix.log
    create_snp_matrix.py -l "$workDir/snplist.txt" -p reads.snp.pileup -o "$workDir/snpma.fasta" "$sampleDirsFile"
_EOF_
)
else
    create_snp_matrix.py -l "$workDir/snplist.txt" -p reads.snp.pileup -o "$workDir/snpma.fasta" "$sampleDirsFile" 2>&1 | tee $logDir/snpMatrix.log
fi    

echo -e "\nStep 8 - Create the reference base sequence"
if [[ "$platform" == "torque" ]]; then
    snpReferenceJobId=$(echo | qsub << _EOF_
    #PBS -N job.snpReference 
    #PBS -d $(pwd)
    #PBS -j oe 
    #PBS -W depend=afterokarray:$snpPileupJobArray
    #PBS -o $logDir/snpReference.log
    create_snp_reference_seq.py -l "$workDir/snplist.txt" -o "$workDir/referenceSNP.fasta" "$referenceFilePath"
_EOF_
)
else
    create_snp_reference_seq.py -l "$workDir/snplist.txt" -o "$workDir/referenceSNP.fasta" "$referenceFilePath" 2>&1 | tee $logDir/snpReference.log
fi

