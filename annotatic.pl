#!/usr/bin/env perl

# Created 10/09/2015
# Nicolas Thierry-Mieg
# Eméric BANKOLE

# Modified by Eméric 25/05/2016

# Take two args: $indir and $outdir, both must pre-exist.
# Every *.vcf file in indir will be analyzed:
# - Step 1: produce $outClean, where we only keep PASS variants
#   that are not homoref. Also, this file has one line per retained 
#   ALT allele, holding only the relevant fields, and with a rebuilt 
#   correct ID column. Also, some vcf lines have different fields
#   (eg DP but no FDP), we disguise these lines as regular lines (see STEP 1B).
# - Step 2: annotate $outClean with VEP, result goes in $outVep.
# - Step 3: ignore all annotation blocks that don't concern an NM 
#   transcript of interest; produce $outCsv (CSV format), with one 
#   line per affected transcript (and per ALT allele as before),
#   holding a selection of the fields from the VCF, in a user-friendly
#   order and presentation.

use strict;
use warnings;
# Encode package used to display accents in excel format
use Encode ;
# POSIX used to display date 
use POSIX qw(strftime);



#####################################################################
##### customizable global vars
#####################################################################

# absolute path of plugin and data etc...
#my $pluginPath = "./" ;
# IBP:
#my $pluginPath = "/results/plugins/Annotatic/" ;

# IBP: on my local computer
#my $pluginPath = "/home/ptfngs/Bureau/Annotatic_v1.9" ;

# IBP: on my external hard drive
my $pluginPath = "/media/ptfngs/Elements/Sauvegarde_home_ubuntu14.04/Annotatic_v1.9" ;


# file holding the list of refseq NM ids for the transcripts of interest.
# format: one line per NM identifier, tab-separated, second column is gene name.
my $NM_file = "$pluginPath/data/NM_ref_PGM_151117.tsv";

# human genome fasta, for VEP --hgvs
my $genome_fasta = "$pluginPath/data/hg19/Homo_sapiens.GRCh37.75.dna.primary_assembly.fa" ;
# IBP old (no longer used):
#my $genome_fasta = "/results/referenceLibrary/tmap-f3/hg19/hg19.fasta" ;

# number of jobs that VEP can generate in parallel (--fork)
#my $jobs = 4 ;
# IBP:
my $jobs = 6 ;

### we need supplementaries info in the final outputfile header like:
### sample name, barcode, Run name, software version (VariantCaller, format vcf file, vcffileDate
### basecallerVersion, tmapVersion)
# All this are added in the annotatic header file. See step 3 for the rest.
my @info_sup =("source","fileformat","tmapVersion") ;

# good fields in INFO column
# these fields are either single-valued, or have as many comma-separated values as ALT column
my @goodFieldsInfoSingle = ("FDP","FRO","FSRF","FSRR");
my @goodFieldsInfoMulti = ("AF","FAO","FSAF","FSAR","HRUN","TYPE");
# other good fields, from FORMAT/indiv column: GT and GQ, get special treatment
# and will become regular INFO fields after step 1 (but GT will be changed to a string)
my @goodFieldsExtra = ("GT","GQ") ;
# NOTE: we will also use OID and OPOS/OREF/OALT from the INFO column if they exist,
# but these are dealt with separately later because they are multi-valued
# but the number of values they have doesn't match the number of ALTs

# NOTE 22/03/2016: many of these INFO fields do not exist in GATK-produced lines,
# and we discovered recently that our input VCF is a merge of 3 VCFs, two of
# which use the fields above but the third is GATK (iused for long indels)
# and it doesn't...
# To deal with this we will disguise the GATK lines into regular lines
# by changing the INFO string before parsing it. See STEP 1B.

# Build the list of desired VEP "Format" names, we'll then print them
# in that order.
# Current available annotations are:
# Allele|Consequence|IMPACT|SYMBOL|Gene|Feature_type|Feature|BIOTYPE|EXON|INTRON|HGVSc|HGVSp|
# cDNA_position|CDS_position|Protein_position|Amino_acids|Codons|Existing_variation|DISTANCE|
# STRAND|VARIANT_CLASS|SYMBOL_SOURCE|HGNC_ID|REFSEQ_MATCH|SIFT|PolyPhen|DOMAINS|
# GMAF|AFR_MAF|AMR_MAF|ASN_MAF|EAS_MAF|EUR_MAF|SAS_MAF|AA_MAF|EA_MAF|CLIN_SIG|SOMATIC|PHENO|PUBMED|
# ExAC_AF_FIN|ExAC_AF_OTH|ExAC_AF|ExAC_AF_AMR|ExAC_AF_AFR|ExAC_AF_EAS|ExAC_AF_NFE|ExAC_AF_SAS|
# CADD_RAW|CADD_PHRED
my @goodVeps = ("Consequence","EXON","INTRON","HGVSc","HGVSp", 
		# CDS_position","Protein_position", replaced CDS_pos and prot_pos by HGVS
		"Amino_acids","Existing_variation",
		"SIFT","PolyPhen","CADD_RAW","CADD_PHRED",
		"DOMAINS","CLIN_SIG",
		"GMAF","AFR_MAF","AMR_MAF","ASN_MAF","EAS_MAF","EUR_MAF","SAS_MAF",
		"AA_MAF","EA_MAF",
		"ExAC_AF","ExAC_AF_NFE","ExAC_AF_AFR","ExAC_AF_FIN","ExAC_AF_OTH","ExAC_AF_AMR",
		"ExAC_AF_EAS","ExAC_AF_SAS",
		"PUBMED");


# New format field annotatic file  ***************************************************************************************** (EB)

# need to change field order in annotatic file to have better presentation for bilogists.
# So we create field and change columns order like this:

# For the first header : 
# Localisation du variant
# Description du variant, valeurs de couvertures et de fréquences
# Annotations cliniques référencées
# Qualité du génotype et détails des référencées selon l'origine géographique

# For the second header : 
# Chromosome  Position  GENE  TRANSCRIPT  EXON  INTRON  HGVSc HGVSp Type de mutation  Profondeur de lecture(FDP)  
# Fréquence allélique(AF) Génotype  GMAF  GMAF_Bis  Conséquence Acides aminés REF ALT Ref Observations(Forward/Reverse) (FRO FSRF/FSRR) 
# Alt Observations (Forward/Reverse) (FAO FSAF/FSAR)  Run Length (HRUN) Base 
# Cosmic Existing_variation  Base ClinVar  Base SIFT Base PolyPhen CADD_PHRED  CADD_RAW  Références PUBMED 
# Qualité du Génotype(GQ) ExAC_AF AFR_MAF AMR_MAF ASN_MAF EAS_MAF EUR_MAF SAS_MAF AA_MAF  EA_MAF  ExAC_AF_NFE ExAC_AF_AFR ExAC_AF_FIN ExAC_AF_OTH ExAC_AF_AMR ExAC_AF_EAS ExAC_AF_SAS

# See step 3 for the rest ...

my @goodVeps_variant_localisation_field = ("Chromosome","Position","GENE","TRANSCRIPT","EXON","INTRON","HGVSc","HGVSp") ;

my @goodVeps_variant_description_field = ("Type de mutation","Profondeur de lecture(FDP)","Frequence allelique(AF)","Genotype","GMAF","GMAF_Bis", "Consequence","Acides amines","REF","ALT",
    "Ref Observations(Forward/Reverse) (FRO FSRF/FSRR)","Alt Observations (Forward/Reverse) (FAO FSAF/FSAR)","Run Length (HRUN)") ;

my @goodVeps_referenced_annotation_field = ("Base Cosmic","Existing_variation","Pathogenicite","Base ClinVar","Base SIFT","Base PolyPhen","CADD_PHRED","CADD_RAW", "References PUBMED", "Commentaires du biologiste") ;

my @goodVeps_MAF_field = ( "Qualite du Genotype(GQ)","ExAC_AF","AFR_MAF","AMR_MAF","ASN_MAF","EAS_MAF","EUR_MAF","SAS_MAF","AA_MAF","EA_MAF","ExAC_AF_NFE","ExAC_AF_AFR","ExAC_AF_FIN","ExAC_AF_OTH",
                "ExAC_AF_AMR","ExAC_AF_EAS","ExAC_AF_SAS") ;

my @allgoodVeps_field = (@goodVeps_variant_localisation_field,@goodVeps_variant_description_field,@goodVeps_referenced_annotation_field,@goodVeps_MAF_field) ;

# ***************************************************************************************************************************




#####################################################################
##### MAIN
#####################################################################

# NM's of interest are stored in %NMs, key==NM, value==gene name
my %NMs = &buildNMs($NM_file);

(@ARGV == 2) || 
    die "USAGE: annotatic.pl <indir> <outdir>\nwhere both subdirs must pre-exist\n" ;

my ($indir, $outdir) = @ARGV ;

((-d $indir) && (-d $outdir)) ||
    die "at least one of indir ($indir) or outdir ($outdir) are not existing dirs\n" ;


# save the output folder name which represent the Run name or report name: this is specific for IonPgm traçability
# It is added in the head of annotatic file. See step 3 for the rest.
my @path_outdir = ();
my $report_name = "None" ;
# $sn2 is a uniq id to identify Run name and report name on pgm server
my $sn2 = "" ;
@path_outdir = split(/\//, $outdir);
($report_name = $path_outdir[5]) ;
($report_name) && ($report_name =~ /(SN2\-\d+)/) && 
  ($sn2 = $1) || (warn "no SN2 value in Run name and report name, may be this run not from pgm ...\n") ;
($report_name) || ($report_name = "None") && (warn "cannot extract report name for this run, may be you are not on IonPgm server 
  so by default name of output folder is taken ...\n") ;

# we save the Run name. It is added in the head of annotatic file.
my $RunName = "None";
my $some_dir = "/results/sn25080250/" ;

# we save the name of biologist team in $team_name
# we save in $first_line first line of file explog.txt which is edited after Run sequencing 
# Same way with Run name.
my $team_name = "None" ;
my $first_line = "" ;
my @first_line_elts = () ;
my @dots = () ;
my $dh;
(-d $some_dir) && (opendir($dh, $some_dir)) || ($some_dir = $outdir) && (warn "/results/sn25080250/ do not exit may be you are not on pgm server") ;
($some_dir ne $outdir) && ( @dots = grep { !/^\./ && !/^\.\./ && -d "$some_dir/$_" } readdir($dh) );

# In the case where you are not in pgm server, we can choose your Run folder. this will be changed clearly later.
($some_dir eq $outdir) && (opendir($dh, $some_dir))  && ( @dots = grep { !/^\./ && !/^\.\./ && -d "$some_dir/$_" } readdir($dh) );

  foreach my $rep (@dots) {
    if ((-d $some_dir."/".$rep) && ($rep =~ /$sn2/)) {
      $RunName = $rep;
    }
  }

  ($RunName) && (-f $some_dir."/".$RunName."/"."explog.txt") && 
  open(F, $some_dir."/".$RunName."/explog.txt" ) && ($first_line = <F>) && 
  ($first_line ne "") && (@first_line_elts = split(/:/, $first_line)) && ($first_line_elts[1] =~ /(.+)_/) && ($team_name = $1) || 
  warn("cannot open explog.txt, may be not exist or not from pgm server, so cannot grab team name ..." ) && ($RunName = "None");
  close(F) ;

closedir $dh;


# Some strange found variant (no goodo*) can die Annotatic process
# To avoid this, create file for bug reporting about these strange variants instead die Annotatic.
# See step 1C for the rest
my $BugReport = "$outdir/BugReportVariants.txt"  ;
open(FileBugVariant, ">$BugReport") ||  die "cannot open BugReportVariants file for writing\n" ;


opendir(INDIR, $indir) || die "cannot opendir indir $indir\n" ;

while (my $infile=readdir(INDIR)) {
    # silently ignore ., .., *.tbi, *.zip
    (($infile eq ".") || ($infile eq "..") || 
     ($infile =~ /\.tbi$/) || ($infile =~ /\.zip$/)) && next;

    # save barcode; it is added in the head of the annotatic file. See Step 3 for the rest.
    my $barcode = "";
    if ($infile =~ /(I.+\d+)\.vcf$/) {
     $barcode = $1 ;
    }
    ($barcode) || warn "cannot extract barcode for this sample, please check vcf file name : $indir/$infile\n" ;

    my $fileRoot = "";
    if ($infile =~ /^(\S+)\.vcf$/) {
	   $fileRoot = $1 ;
    }
    else {
      warn "infile is not .vcf or has whitespaces in filename, skipping $indir/$infile\n" ;
      next ;
    }

    warn "Starting analysis of $infile\n" ;

    # build the output filenames:
    # $outClean: cleaned up VCF file, holding the portions of lines from $infile
    # that have at least one variant read, with a single ALT allele per line, etc...
    # see STEP 1 comments for details.
    my $outClean = "$outdir/${fileRoot}_clean.vcf" ;
    # $outVep: VCF file produced by VEP when run on $outClean
    my $outVep = "$outdir/${fileRoot}_clean_vep.vcf" ;
    # $outCsv: final CSV file, built from $outVep but keeping only selected
    # VEP annotations and ignoring CSQ blocks that don't concern our good %NMs
    my $outCsv = "$outdir/${fileRoot}_annotatic.txt" ;
    # We create another annotatic file in new format (see step 3 for details)
    my $new_outCsv = "$outdir/${fileRoot}_annotatic_new.txt" ;

    # save annotatic file date
    my $AnnotaticFileDate = strftime " %Y%m%d %H:%M:%S ", localtime;




    #####################################################################
    ##### STEP  1
    #####################################################################

    # - remove positions whose FILTER status is not PASS;
    # - remove positions whose genotype is 0/0==homoref;
    # - only keep ALT alleles that appear in the called genotype GT;
    # - disguise GATK lines as normal lines;
    # - only keep the ID (COSM, grabbed in OID) for variants that are actually called.
    # 
    # [OBOSOLETE: this filter has been removed, it resulted in too many false negatives:
    #     - remove positions where the OPOS for all retained ALT alleles doesn't match 
    #       the current coordinate +-1 (buggy ion torrent variant caller / annotator);
    # [END OF OBSOLETE]
    #
    # When a line has several called variant alleles:
    # - split into one line per variant allele.
    #   
    # Store the cleaned file in $outClean.
    # Store strange variant supposed to block annotatic in $bug_report.

    open(IN,"$indir/$infile") || die "cannot open $indir/infile for reading\n" ;
    open(OUT, ">$outClean") ||	die "cannot open $outClean for writing\n" ;
    
    # lines to be printed are stored in array and sorted+printed only
    # when we change CHROMs
    my @outBuffer = () ;
    my $prevChr = "" ;
    my $sample = "" ;
    my %info_sup_record = () ;

  LINES1: while(my $line = <IN>) {
      chomp $line;
      # header lines: just copy
      if ($line =~ /^#/) {
        if ($line =~ /^#CHROM/) {
          # save sample name. It is added in the head of annotatic file. See Step 3 for the rest.
          my @field_name = split(/\t/,$line) ;
          $sample = "$field_name[9]" ;
          ($sample) || warn "cannot extract patient name in line : $line, from this vcf file : $indir/$infile\n" ; 
        }

        # save additional information about software version. These informations are added in the head of annotatic file
        # See Step 3 for the rest.
        foreach my $sup (@info_sup) {
          if ($line =~ /##$sup=/) {
            $info_sup_record{$sup} = $';
            $info_sup_record{$sup} || warn "cannot extract info from $sup, please check vcf file header in:\n$line\n" ;
          }
        }

        

	    print OUT "$line\n";
	    next;
      }

      my ($chr,$pos,$id,$ref,$alt,$qual,$filter,$info,$format,$indiv) = split(/\t/,$line);
      my @alts = split(/,/,$alt) ;
      # normalize $info: add leading and trailing ';'
      $info = ";$info;" ;
      # initialize $prevChr
      ($prevChr) || ($prevChr = $chr) ;


      #####################################################################
      ##### STEP 1Z: print buffer lines if we changed chrom
      #####################################################################
      if ($prevChr ne $chr) {
	  foreach my $line (sort sortVCF @outBuffer) {
	      print OUT "$prevChr\t$line" ;
	  }
	  $prevChr = $chr ;
	  @outBuffer = () ;
      }



      #####################################################################
      ##### STEP 1A: filter out bad lines and/or bad ALT alleles
      #####################################################################

      ######################################################
      # FILTER 1: only keep FILTER==PASS lines

      ($filter eq "PASS") || next;


      ######################################################
      # FILTER 2: only keep ALT alleles that were called

      # examine called genotype:
      # grab GT and GQ indexes (GQ changes position from line to line!!) in FORMAT
      my @format = split(/:/,$format) ;
      my @indiv = split(/:/,$indiv) ;
      my ($geno1,$geno2,$genoq) = ("","","");
      foreach my $f (0..$#format) {
	  if ($format[$f] eq "GT") {
	      my $geno = $indiv[$f] ;
	      if ($geno !~ /^(\d+)\/(\d+)/) {
		  warn "Skipping line in $infile: in step 1, cannot extract genotype from geno $geno in line:\n$line\n" ;
		  next LINES1;
	      }
	      ($geno1,$geno2) = ($1,$2);
	  }
	  elsif ($format[$f] eq "GQ") {
	      $genoq = $indiv[$f] ;
	  }
	  ($genoq ne "") && ($geno1 ne "") && last ;
      }
      # skip homoref positions
      if (($geno1==0) && ($geno2==0)) {
	  next;
      }

      # sanity: called genotypes exist in @alts
      ((@alts >= $geno1) && (@alts >= $geno2)) ||
	  die "in step 1: genotype values $geno1:$geno2 but not enough ALT alleles $alt\nLine is $line\n" ;
      # build indexes (in @alts and in future goodFieldsInfoMulti) of
      # alt alleles that were actually called
      my @goodAltIndexes = () ;
      ($geno1 != 0) && (push(@goodAltIndexes,$geno1-1)) ;
      ($geno2 != 0) && ($geno2 != $geno1) && (push(@goodAltIndexes,$geno2-1)) ;


      #####################################################################
      ##### STEP 1B: disguise lines produced by GATK (used for long indel 
      ##### calls) as regular torrent-caller lines
      #####################################################################

      # some F** fields (eg FDP) don't exist, we'll use DP etc instead.
      # Their types (InfoSingle or InfoMulti) don't change.
      # HRUN  doesn't exist.
      # fields to which we add a leading F
      my @addF = ("DP", "RO", "SRF", "SRR", "AO", "SAF", "SAR");
      
      # use the absence of FDP to identify these lines
      if ($info !~ /;FDP=/) {
	  foreach my $f (@addF) {
	      $info =~ s/;$f=/;F$f=/ ;
	  }
	  # add bogus missing fields
	  $info .= "HRUN=NA" . ",NA"x $#alts .";" ;
      }

      #####################################################################
      ##### STEP 1C: build ID values and grab good OREF/OALT/OPOS for called variants
      #####################################################################

      # Build the IDs for each goodAlt, one ID string per goodAlt. This
      # is stored in @ids, indexed by the indexes of @goodAltIndexes.
      my @ids = () ;
      # We also construct arrays @goodoref, @goodoalt and @goodopos, also 
      # indexed by the indexes of @goodAltIndexes, holding the "correct"
      # REF/ALT/POS of the corresponding alt allele.
      # "correct" will be the "original" values (from OREF/OPOS/OALT) for SNPs,
      # but they will be adjusted for indels (so we don't get "-" refs/alts)
      my @goodoref = ();
      my @goodoalt = ();
      my @goodopos = ();

      # following block to limit scope of local variables
      {
	  # We grab the good IDs in OID field, taking the OIDs whose OMAPALT
	  # matches each goodAlt.
	  # We will use these in the ID line instead of the initial content if
	  # that ID column, which cannot be used (see NOTE below).
	  # NOTE: we can have 2 COSM ids in ID, 2 ALT alleles, but 
	  # 3 OID+OMAPALT... Example:
	  # chr3	178952041	COSM1663505;COSM1663504	G	A,C [...]
	  # OID=.,COSM1663505,COSM1663504;OPOS=178952041,178952041,178952041;OREF=G,G,G;OMAPALT=A,C,C;
	  # In this case the A ALT allele is not present in either COSM!
	  # So, we must discard $id and use OID based on OMAPALT...
	  my @oid = ();
	  my @omapalt = ();
	  my @oalt = ();
	  my @oref = ();
	  my @opos = ();

	  if ($info =~ /OID=([^;]+);/) {
	      @oid = split(/,/,$1) ;
	  }
	  if ($info =~ /OMAPALT=([^;]+);/) {
	      @omapalt = split(/,/,$1) ;
	  }
	  if ($info =~ /OALT=([^;]+);/) {
	      @oalt = split(/,/,$1) ;
	  }
	  if ($info =~ /OREF=([^;]+);/) {
	      @oref = split(/,/,$1) ;
	  }
	  if ($info =~ /OPOS=([^;]+);/) {
	      @opos = split(/,/,$1) ;
	  }

	  ((@oid == @omapalt) && (@oid == @oalt) && (@oid == @oref) && (@oid == @opos) ) ||
	      die "in step 1C: not same number of values in oid and omapalt/oalt/oref/opos in:\n$line\n" ;

	  # grab good O* corresponding to goodAlts
	  foreach my $i (0..$#goodAltIndexes) {
	      $ids[$i] = "" ;
	      $goodoref[$i] = "";
	      $goodoalt[$i] = "";
	      $goodopos[$i] = "";
	      foreach my $j (0..$#oid) {
		  if ($omapalt[$j] eq $alts[$goodAltIndexes[$i]]) {
		      # the j-th OMAPALT matches the i-th goodAlt
		      my ($newGoodRef,$newGoodAlt,$newGoodPos) ;

		      # we trust the upstream regularization of variants, so assume
		      # that if omapalt matches alt the corresponding OID is good
		      if ($oid[$j] ne ".") {
    			  # this o* has an OID and it's not '.'
    			  ($ids[$i]) && ($ids[$i] .= ";") ;
    			  $ids[$i] .= $oid[$j] ;
		      }

		      # whenever oref and oalt are not "-", use oref/oalt/opos
		      if (($oref[$j] ne "-") && ($oalt[$j] ne "-")) {
    			  $newGoodRef = $oref[$j] ;
    			  $newGoodAlt = $oalt[$j] ;
    			  $newGoodPos = $opos[$j] ;
		      }
		      elsif ($oref[$j] eq "-") {
			  # insertion
			  # we can't have both oref and oalt be "-", check it
			  ($oalt[$j] ne "-") || die "in step 1C, both oref and oalt are - at index $j, impossible? in:\n$line\n" ;
			  # we will grab the single base preceding the insertion from $ref,
			  # and also add that base in front of oalt
			  # NOTE: COSMIC variants are not regularized but it seems upstream
			  # variant caller does the regularization to identify equivalent indels.
			  # We assume here that one of the equivalent COSMIC entries matches the REF/ALT
			  # regularization performed by the variant caller, and we only use that entry.
			  # This assumption isn't dangerous because if it isn't met we will have no 
			  # $goodoref[$i] and therefore die cleanly later.
			  # See AnnotaticBug_Emeric_161020/ and emails around 03/11/2016.
			  my @splitref = split(//, $ref) ;
			  if ($#splitref < $opos[$j]-$pos-1) {
			      warn "in step 1C: the OID number $j is an insertion seemingly matching variant $i but coordinates dont fit, an equivalent OID will (should) be used, ignoring this OID. Line is:\n$line\n" ;
			      next ;
			  }
			  my $baseToAdd = $splitref[$opos[$j]-$pos-1];

			  $newGoodRef = $baseToAdd ;
			  $newGoodAlt = $baseToAdd.$oalt[$j] ;
			  $newGoodPos = $opos[$j]-1 ;
		      }
		      else {
			  # oref is not "-" but oalt=="-" : this is a deletion, we will
			  # grab the single base preceding the deletion for alt and also
			  # add that base in front of oref
			  # NOTE: same idea as for insertions regarding regularization, see above NOTE.
			  my @splitmapalt = split(//, $omapalt[$j]) ;
			  if ($#splitmapalt < $opos[$j]-$pos-1) {
			      warn "in step 1C: the OID number $j is a deletion seemingly matching variant $i but coordinates dont fit, an equivalent OID will (should) be used, ignoring this OID. Line is:\n$line\n" ;
			      next ;
			  }
			  my $baseToAdd = $splitmapalt[$opos[$j]-$pos-1];

			  $newGoodRef = $baseToAdd.$oref[$j] ;
			  $newGoodAlt = $baseToAdd ;
			  $newGoodPos = $opos[$j]-1 ;
		      }

		      # sanity: if we find several orefs they shoud be identical
		      (! $goodoref[$i]) || ($goodoref[$i] eq $newGoodRef) ||
			  (warn "in step 1C: found several different goodoref for variant $i, discarding $goodoref[$i] and using the latest ie $newGoodRef . Line is:\n$line\n") ;
		      (! $goodoalt[$i]) || ($goodoalt[$i] eq $newGoodAlt) ||
			  (warn "in step 1C: found several different goodoalt for variant $i, discarding $goodoalt[$i] and using the latest ie $newGoodAlt . Line is:\n$line\n") ;
		      (! $goodopos[$i]) || ($goodopos[$i] eq $newGoodPos) ||
			  (warn "in step 1C: found several different goodopos for variant $i, discarding $goodopos[$i] and using the latest ie $newGoodPos . Line is:\n$line\n") ;

		      $goodoref[$i] = $newGoodRef ;
		      $goodoalt[$i] = $newGoodAlt ;
		      $goodopos[$i] = $newGoodPos ;
		  }
	      }
	      # if no IDs found, use '.'
	      ($ids[$i]) || ($ids[$i] = ".") ;

        # sanity: we need a goodo* for each goodAltIndex 
        # Modify sanity of Nicolas because we have some case of variant which have not at least a goodo* and Annotatic die because of it.
        # So to avoid annotatic dying we report in a report file (BugVariantReport.txt) for biologists these variants that can block Annotatic process.
        ($goodoref[$i] && $goodoalt[$i] && $goodopos[$i]) || 
        (warn "in step 1C: no goodoref/goodoalt/goodopos found for good variant $i, FIXME!; please check BugReportVariants.txt or click BugReportVariants tab for details Line is:\n$line\n") && 
        (print FileBugVariant "For the patient (Name: $sample;  Barcode: $barcode)\n\n") && (print FileBugVariant "$line\n") && 
        (print FileBugVariant "\n   ___________________ \n\n") && (next LINES1) ;
        
	  }


      }

      #####################################################################
      ##### STEP 1D: grab good fields from INFO
      #####################################################################


      # OK, grab good fields from INFO, stuff into %data:
      # single-valued fields go as strings, multi-valued
      # go as array refs but we only keep the values for @goodAlts
      my %data = () ;
      # single-valued -> string
      foreach my $f (@goodFieldsInfoSingle) {
	  if ($info !~ /;$f=([^;]+);/) {
	      warn "Skipping line in $infile: cannot extract value for $f in:\n$line\n" ;
	      next LINES1;
	  }
	  $data{$f} = $1 ;
      }
      # multi-valued
      foreach my $f (@goodFieldsInfoMulti) {
	  if ($info !~ /;$f=([^;]+);/) {
	      warn "Skipping line in $infile: cannot extract value for $f in:\n$line\n" ;
	      next LINES1;
	  }
	  my @vals = split(/,/,$1) ;
	  # sanity
	  (@vals == @alts) ||
	      die "in step 1: multi-field $f has wrong number of values (@vals) compared to alts (@alts):\n$line\n" ;
	  my @goodVals = () ;
	  foreach my $i (@goodAltIndexes) {
	      push(@goodVals, $vals[$i]) ;
	  }
	  $data{$f} = \@goodVals ;
      }


      #####################################################################
      ##### STEP 1E: prepare output lines, one line per alt allele if it was called
      #####################################################################

      foreach my $i (0..$#goodAltIndexes) {
	  #take good ref from OREF, good alt from OALT and good position from OPOS. 
	  push(@outBuffer, "$goodopos[$i]\t$ids[$i]\t$goodoref[$i]\t$goodoalt[$i]\t$qual\t$filter\t") ;
	  # NEW INFO COLUMN:
	  # construct new GT string: HET or HOMOVAR
	  my $geno = "HET" ;
	  # this covers: two lines (HET VAR1:VAR2, we say HET on both lines)
	  # as well as one line with different genos (must be 0/x or x/0).
	  # the only case that's not HET is HOMOVAR when both genos are equal
	  ($geno1 == $geno2) && ($geno = "HOMOVAR") ;
	  $outBuffer[$#outBuffer] .= "GT=$geno;GQ=$genoq" ; # no trailing ';', we'll add it later to avoid the final ';'
	  
	  # fill remaining good INFO fields
	  
	  foreach my $f (@goodFieldsInfoSingle) {
	      $outBuffer[$#outBuffer] .= ";$f=".$data{$f} ;
	  }

	  # Conversion of allelic frequency in percentage
	  foreach my $f (@goodFieldsInfoMulti) {
	      # for AF we want the freq as a percentage
	      ($f eq "AF") && (${$data{$f}}[$i] = sprintf("%.0f", (${$data{$f}}[$i] * 100))."%") ;
	      # for TYPE: some SNPs are incorrectly marked MNP, fix it
	      if (($f eq "TYPE") && (${$data{$f}}[$i] ne "snp") && 
		  ($goodoref[$i] =~ /^[ATGCatgc]$/) && ($goodoalt[$i] =~ /^[ATGCatgc]$/) ) {
		  warn "INFO in $infile: in step 1E we changed the type of a SNP to snp at $prevChr $goodopos[$i]" ;
		  ${$data{$f}}[$i] = "snp" ;
	      }
	      $outBuffer[$#outBuffer] .= ";$f=".${$data{$f}}[$i] ;
	  }
	  # OK, we don't keep FORMAT and indiv lines, useless
	  $outBuffer[$#outBuffer] .= "\n" ;
      }
  }
    close(IN);
    # output for last chrom
    foreach my $line (sort sortVCF @outBuffer) {
	print OUT "$prevChr\t$line" ;
    }
    close(OUT);


    #####################################################################
    ##### STEP  2: annotate with VEP
    #####################################################################

    # annotate $outClean with VEP, result goes in $outVep

    my $vepCommand = "perl $pluginPath/VEP_81/variant_effect_predictor.pl" ;
    $vepCommand .= " --dir_cache $pluginPath/VEP_81/cache --dir_plugins $pluginPath/VEP_81/plugins" ;
    $vepCommand .= " --offline --refseq --vcf" ;
    $vepCommand .= " --force_overwrite --no_progress --no_stats" ;
    # instead of --everything we select relevant options (eg not --regulatory)
    $vepCommand .= " --sift b --polyphen b --symbol --numbers --domains" ;
    $vepCommand .= " --gmaf --maf_1kg --maf_esp --pubmed --variant_class" ;
    $vepCommand .= " --fasta $genome_fasta --hgvs" ;
    # plugins
    $vepCommand .= " --plugin ExAC,$pluginPath/data/ExAC/ExAC.r0.3.sites.vep.vcf.gz" ;
    $vepCommand .= " --plugin CADD,$pluginPath/data/CADD/whole_genome_SNVs.tsv.gz,$pluginPath/data/CADD/InDels.tsv.gz" ;
    # --fork borks when $jobs==1
    ($jobs > 1) && ($vepCommand .= " --fork $jobs") ;
    $vepCommand .= " -i $outClean -o $outVep" ;

    system($vepCommand) ;


    #####################################################################
    ##### STEP  3
    #####################################################################

    # Ignore all VEP annotation blocks that don't concern an NM transcript
    # of interest;
    # also, select VEP annotations of interest (@goodVeps);
    # print results to $outCsv
    # print results to $new_outCsv. It is new annotatic file format (add Emeric 16/11/08)

    # VEP doesn't produce any file when the infile has no variants.
    # detect when this happens and skip to next infile.
    if (! -f $outVep) {
	warn "Starting step 3 but file $outVep does not exist, maybe no variants? Skipping this file\n" ;
	next;
    }

    open(IN,"$outVep") || die "cannot open $outVep for reading in step 3\n" ;
    open(OUT,">$outCsv") || die "cannot open $outCsv for writing in step 3\n" ;
    open(new_OUT,">$new_outCsv") || die "cannot open $new_outCsv for writing in step 3\n" ; #(add Emeric 16/11/08)

    # headers: ignore them but grab the VEP CSQ field names and store
    # them in @vepNames
    my @vepNames;
    while (my $line = <IN>) {
	chomp($line);
	($line =~ /^#/) ||
	    die "in step 3, parsing header but found non-header line:\n$line\n" ;

	# special cases: VEP CSQ header, and #CHROM (==last header line)
	if ($line =~ /^##INFO=<ID=CSQ/) {
	    ($line =~ /Format: ([^"]+)">$/) ||
		die "found CSQ header line but can't find Format:\n$line\n" ;
	    @vepNames = split(/\|/,$1);
	}
	elsif ($line =~ /^#CHROM/) {
	    last;
	}
    }
    (@vepNames) || 
	die "in step 3, done parsing headers but vepNames still empty! Infile: $outVep\n" ;

    # all fields are now single-valued thanks to step 1, except CSQ in $info
    # Also, we know the order they appear in INFO since we built it (except CSQ 
    # but VEP always seems to add it at the end, we'll check that):
    # INFO will have following fields, in that order:
    my @allFields = (@goodFieldsExtra,@goodFieldsInfoSingle,@goodFieldsInfoMulti,"CSQ") ;

    # building header for new annotatic file *************************************************************** (EB)

    # Add Patient information and software information in the header
    # For traçability we keep informations about version of software used on pgm server from header of vcf file
    print new_OUT "Equipe :\t$team_name\n" ;
    print new_OUT "N° Patient : \t$sample\n" ;
    print new_OUT "Barcode : \t$barcode\n" ;
    print new_OUT "Run name : \t$RunName\n" ;
    print new_OUT "Report Name : \t$report_name\n" ;
    print new_OUT "Annotatic version : \tv1.9\n" ;
    print new_OUT "AnnotaticFileDate : \t$AnnotaticFileDate\n" ;
    
    # We take good version of TVC so wrong with version in vcf file header
    $info_sup_record{"source"} = "Torrent VariantCaller (v5.0.4.0)" ;
    my $source = $info_sup_record{"source"} ;
    my $vcffileversion = $info_sup_record{"fileformat"} ;
    my $tmapVersion = $info_sup_record{"tmapVersion"} ;
    ($source) || ($vcffileversion) || ($tmapVersion) || warn "Cannot extract software version information, may be the input vcf file is not from IonPgm server, please check it!!\n" ;

    print new_OUT "tmapVersion : \t$tmapVersion\n" ;
    print new_OUT "source : \t$source\n" ;
    print new_OUT "VCF File version : \t$vcffileversion\n" ;
    print new_OUT "\n" ;



    # Add new field name
    print new_OUT "| ***\t\t\t\tLocalisation du variant\t\t\t*** |\t" ;
    print new_OUT " | ***\t\t\t\t\t\t\tDescription du variant, valeurs de couvertures et de frequences\t\t\t\t\t\*** | " ; 
    print new_OUT " \t| ***\t\t\tAnnotations cliniques referencees\t\t\t\t***| " ; 
    print new_OUT " \t| ***\t\t\t\t\t\t\t\tQualite du genotype et details des References selon l'origine geographique\t\t\t\t\t\t\t\t*** | " . "\n" ;

    # Edit column and group them by field
    foreach my $x_field (@allgoodVeps_field) {
    	print new_OUT "$x_field\t" ;
    }
    print new_OUT "\n" ;

    # *******************************************************************************************************

    # Below is the old format of annotatic file (BE)
    # Add Patient name and barcode in the head
    # Add Report name or Run name and version of software used in the pipeline of pgm server
    print OUT "Equipe : \t$team_name\n" ;
    print OUT "N° Patient : \t$sample\n" ;
    print OUT "Barcode : \t$barcode\n" ;
    print OUT "Run name : \t$RunName\n" ;
    print OUT "Report Name : \t$report_name\n" ;
    print OUT "Annotatic version : \tv1.9\n" ;
    print OUT "AnnotaticFileDate : \t$AnnotaticFileDate\n" ;

    print OUT "tmapVersion : \t$tmapVersion\n" ;
    print OUT "source : \t$source\n" ;
    print OUT "VCF File version : \t$vcffileversion\n" ;
    print OUT "\n" ;

    # Make our own headers for the CSV
    print OUT "CHROM\tPOS\tGENE\tTRANSCRIPT\tTYPE\tREF\tALT\tVARIANT ID" ;
    ### Above uses HGNC_ID and Feature from VEP, all initial VCF fields
    ### (except FILTER which we discard, since we only keep PASSED variants,
    ### and QUAL since it's redundant with GQ), and TYPE from %data.
    ### same order must be used below, when building $outline
    print OUT "\tCALLED GENOTYPE (GT)\tCALL QUALITY (GQ)\tRun Length (HRUN)" ;
    print OUT "\tDEPTH (FDP)\tAllele Frequency (AF)" ;
    print OUT "\tRef Observations (Forward/Reverse) (FRO FSRF/FSRR)" ;
    print OUT "\tAlt Observations (Forward/Reverse) (FAO FSAF/FSAR)" ;

    # OK, now I want to print selected VEP annotations.

    foreach my $vepName (@goodVeps) {
	print OUT "\t$vepName" ;
    }
    print OUT "\n" ;


    # data lines
    while (my $line = <IN>) {
	chomp($line);

	my ($chr,$pos,$id,$ref,$alt,$qual,$filter,$info) = split(/\t/,$line);

	# at this point every dataline from IN should result in at least 
	# one line printed to OUT. Otherwise we are probably missing
	# a good NM in $NM_file. Use $printed as bool for this.
	my $printed = 0;

	# parse $info into %data, keys are from @allFields, data is the string value
	my %data = () ;
	my @infos = split(/;/,$info) ;
	(@infos == @allFields) ||
	    die "in step 3, splitting info doesn't produce correct number of fields:\n$line\n" ;
	foreach my $i (0..$#infos) {
	    ($infos[$i] =~ /^$allFields[$i]=(.+)$/) ||
		die "in step 3, info at index $i cannot be parsed or has wrong field name:\n$line\n" ;
	    $data{$allFields[$i]} = $1 ;
	}

	# now split the VEP CSQ field
	my @csqs = split(/,/, $data{"CSQ"}) ;
	
	foreach my $thisCsq (@csqs) {
	    # third arg to split, -1, to generate elements even if last ones are empty
	    my @csqTmp = split(/\|/, $thisCsq, -1) ;
	    my %thisCsq ;
	    (@csqTmp == @vepNames) || 
		die "in step 3, wrong number of fields in CSQ (full line is below): $thisCsq\n$line\n" ;
	    foreach my $i (0..$#vepNames) {
		# replace all slashes by backslashes, for excel :(
		$csqTmp[$i] =~ s~/~\\~g ;
		$thisCsq{$vepNames[$i]} = $csqTmp[$i] ;
	    }

	    # RefSeq id is in Feature field
	    my $fullNM = $thisCsq{"Feature"};
	    # The full refseq ID is something like NM_001242891.1 but %NMs
	    # only contains eg NM_001242891
	    ($fullNM =~ (/^([^\.]+)\.\d+$/)) ||
		((warn "in step 3, cannot split RefSeq ID $fullNM, skipping CSQ block: $thisCsq\n") && next) ;

	    if (defined $NMs{$1}) {
		($thisCsq{"HGNC_ID"} ne "") && 
		    die "thisCsq already has a HGNC_ID value?? $thisCsq\n$line\n" ;
		$thisCsq{"HGNC_ID"} = $NMs{$1} ;

		# modify "HGVSc" and "HGVSp" 's field: remove NM_* component (BE)
		(! $thisCsq{"HGVSc"}) || ($thisCsq{"HGVSc"} =~ s/^[A-Z]+_\d+.\d://) || 
		    (warn "could not remove refseq ID from HGVSc, FIXME? ".$thisCsq{"HGVSc"}."\n") ;
		(! $thisCsq{"HGVSp"}) || ($thisCsq{"HGVSp"} =~ s/^[A-Z]+_\d+.\d://) || 
		    (warn "could not remove refseq ID from HGVSp, FIXME? ".$thisCsq{"HGVSp"}."\n") ;

		
		
		# Build and print a CSV line (Below is the old format of annotatic file (add Emeric 16/11/08)
		my $outline = "$chr\t$pos";
		# gene is HGNC_ID, transcript is Feature
		$outline .= "\t".$thisCsq{"HGNC_ID"}."\t".$thisCsq{"Feature"};
		$outline .= "\t".$data{"TYPE"} ;
		$outline .= "\t$ref\t$alt\t$id" ;

		# everything else is in %data, except VEP stuff which is in %thisCsq.
		# just pick the desired fields in the desired order and print them!
		# Selection must be identical to the header line above.
		# Available %data fields:"FDP","FRO","FSRF","FSRR",
		# "AF","FAO","FSAF","FSAR","HRUN","TYPE", "GT","GQ"
		$outline .= "\t".$data{"GT"}."\t".$data{"GQ"}."\t".$data{"HRUN"} ;
		$outline .= "\t".$data{"FDP"}."\t".$data{"AF"} ;
		$outline .= "\t".$data{"FRO"}."(".$data{"FSRF"}."/".$data{"FSRR"}.")" ;
		$outline .= "\t".$data{"FAO"}."(".$data{"FSAF"}."/".$data{"FSAR"}.")" ;

		# OK, VEP annotations from @goodVeps now:
		foreach my $vepName (@goodVeps) {
		    $outline .= "\t".$thisCsq{"$vepName"} ;
		}

		# ********************************* Build and print line in new annotatic format file **************************************** (EB)

    #  Filling the column of variant localisation field

    my $new_outline = "$chr\t$pos" ;
    $new_outline .= "\t".$thisCsq{"HGNC_ID"}."\t".$thisCsq{"Feature"} ;
    $new_outline .= "\t".$thisCsq{"EXON"}."\t".$thisCsq{"INTRON"}."\t".$thisCsq{"HGVSc"}."\t".$thisCsq{"HGVSp"} ;

    #  Filling the column of variant description and coverage value
    $new_outline .= "\t".$data{"TYPE"}."\t".$data{"FDP"}."\t".$data{"AF"}."\t".$data{"GT"}."\t".$thisCsq{"GMAF"} ;

    my $GMAF_Bis = $thisCsq{"GMAF"} ;

    (! $GMAF_Bis) || ($GMAF_Bis =~ s/[A-Z]+://) || ($GMAF_Bis =~ s/[-]://) || 
      (warn "could not remove letter in GMAF_Bis value, FIXME? ".$thisCsq{"GMAF"}."\n") ;

    $new_outline .= "\t".$GMAF_Bis."\t".$thisCsq{"Consequence"}."\t".$thisCsq{"Amino_acids"}."\t".$ref."\t".$alt ;
    $new_outline .= "\t".$data{"FRO"}."(".$data{"FSRF"}."/".$data{"FSRR"}.")" ;
    $new_outline .= "\t".$data{"FAO"}."(".$data{"FSAF"}."/".$data{"FSAR"}.")"."\t".$data{"HRUN"} ;


    # Filling the column of "Referenced annotations"
    $thisCsq{"pathogenicite"} = "";
    $thisCsq{"commentaires_biologiste"} = "";
    $new_outline .= "\t".$id."\t".$thisCsq{"Existing_variation"}."\t".$thisCsq{"pathogenicite"}."\t".$thisCsq{"CLIN_SIG"}."\t".$thisCsq{"SIFT"}."\t".$thisCsq{"PolyPhen"} ;
    $new_outline .= "\t".$thisCsq{"CADD_PHRED"}."\t".$thisCsq{"CADD_RAW"}."\t".$thisCsq{"PUBMED"}."\t".$thisCsq{"commentaires_biologiste"} ;

    # Filling the column of "Reference and frequency by geographical origin" field
    $new_outline .= "\t".$data{"GQ"}."\t".$thisCsq{"ExAC_AF"}."\t".$thisCsq{"AFR_MAF"}."\t".$thisCsq{"AMR_MAF"}."\t".$thisCsq{"ASN_MAF"}."\t".$thisCsq{"EAS_MAF"} ;
    $new_outline .= "\t".$thisCsq{"EUR_MAF"}."\t".$thisCsq{"SAS_MAF"}."\t".$thisCsq{"AA_MAF"}."\t".$thisCsq{"EA_MAF"} ;
    $new_outline .= "\t".$thisCsq{"ExAC_AF_NFE"}."\t".$thisCsq{"ExAC_AF_AFR"}."\t".$thisCsq{"ExAC_AF_FIN"}."\t".$thisCsq{"ExAC_AF_OTH"} ;
    $new_outline .= "\t".$thisCsq{"ExAC_AF_AMR"}."\t".$thisCsq{"ExAC_AF_EAS"}."\t".$thisCsq{"ExAC_AF_SAS"} ;

		# ****************************************************************************************************************************

		
		# ALL DONE, final newline
		$outline .= "\n" ;
		#For the new format (add Emeric 16/11/08)
		$new_outline .= "\n" ;
		# 17/11/2015: HGVS has %3D instead of = for synonymous snps, fixing
		$outline =~ s/%3D/=/ ;
		#For the new format (add Emeric 16/11/08)
		$new_outline =~ s/%3D/=/ ;
		print OUT $outline ;
		#For the new format (add Emeric 16/11/08)
		print new_OUT $new_outline ;
		$printed = 1;
	    }
	    # else this isn't a good refseq transcript, skip
	}
	# make sure at least one line was printed for this dataline
	($printed) || 
	    warn "In step 3: no 'good RefSeq' annotation block found, ignoring variant! STRANGE!\n$line\n" ;
    }

    close(IN);
    close(OUT);
    #For the new format (EB)
    close(new_OUT);

    #####################################################################
    ##### STEP  4: Rename Annotatic file 
    #####################################################################

    # We want to rename annotatic results file Example: TSVC_variants_barcode_annotatic.txt becomes TSVC_sample-name_barcode_annotatic.txt.
    my $old_outClean = $outClean ;
    my $old_outVep = $outVep ;
    my $old_outCsv = $outCsv ;
    my $old_new_outCsv = $new_outCsv ;

    ($sample) && ($outClean =~ s/TSVC_variants_$barcode/$sample\_$barcode\_TSVC/g) && ($outVep =~ s/TSVC_variants_$barcode/$sample\_$barcode\_TSVC/g) && ($outCsv =~ s/TSVC_variants_$barcode/$sample\_$barcode\_TSVC/g) && 
    ($new_outCsv =~ s/TSVC_variants_$barcode/$sample\_$barcode\_TSVC/g) && (rename $old_outClean, $outClean) && (rename $old_outVep, $outVep) && (rename $old_outCsv, $outCsv) && (rename $old_new_outCsv, $new_outCsv) || 
    (warn "cannot replace barcode by patient name in annotatic output file; May be no patient name in vcf file :  $indir/$infile ; please check it !!\n");

}

closedir(INDIR) ;




# return hash of NMs of interest
sub buildNMs {
    (@_ == 1) || die "buildNMs takes a single arg: the NM filename\n" ;
    my ($NM_file) = @_ ;
    my %goodNMs = () ;
    (-f $NM_file) ||
	die "Need a file with NM's of interest in NM_file (currently $NM_file)\n" ;
    open(NM,$NM_file) || 
	die "cannot open NM_file $NM_file for reading\n" ;
    while(my $line = <NM>) {
	# NM file may be in DOS format, remove all trailing \n\r
	$line =~ s/[\n\r]*$//;
	#ignore blank lines
	($line =~ /^\s*$/) && next ;
	# file should have two tab-separated fields: refseq ID and gene name
	my ($nm,$gene) = split(/\t/,$line) ;
	# ignore trailing whitespace...
	$nm =~ s/\s+$// ;
	# some NM ids have .\d+ at the end, others don't, we ignore the .\d+ (version)
	$nm =~ s/\.\d+$// ;
	($nm =~ /^N[MRC]_\d+$/) || 
	    ((warn "badly formatted NM identifier in NM_file, skipping this line: $line\n") &&
	     next) ;
	# make sure we had a second field with gene
	($gene) || 
	    ((warn "NM line has refeq ID but no gene name, skipping this line: $line\n") &&
	     next);

	if (defined $goodNMs{$nm}) {
	    if ($goodNMs{$nm} eq $gene) {
		warn "WARNING: NM_file has the same NM twice (ignoring .\\d+ extension), same gene name: $nm\n" ;
	    }
	    else {
		die "ERROR: NM_file has the same NM twice (ignoring .\\d+ extension) with different gene names! $nm\n" ;
	    }
	}
	else {
	    $goodNMs{$nm} = $gene;
	}
    }
    close(NM) ;
    return(%goodNMs);
}


# custom sort for vcf lines without CHROM: sort by POS
sub sortVCF {
    ($a =~ /^([^\t]+)\t/) || die "in sortVCF cannot extract pos1 from $a\n" ;
    my $pos1 = $1 ;
    ($b =~ /^([^\t]+)\t/) || die "in sortVCF cannot extract pos2 from $b\n" ;
    my $pos2 = $1 ;
    return($pos1 <=> $pos2) ;
}
