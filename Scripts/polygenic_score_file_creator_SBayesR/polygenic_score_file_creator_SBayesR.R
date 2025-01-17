#!/usr/bin/Rscript
# This script was written by Oliver Pain whilst at King's College London University.
# The script was adjusted by Remo Monti to allow for other parameter settings.
start.time <- Sys.time()
suppressMessages(library("optparse"))

option_list = list(
make_option("--ref_plink", action="store", default=NA, type='character',
		help="Path to per chromosome reference PLINK files [required]"),
make_option("--ref_keep", action="store", default=NA, type='character',
		help="Keep file to subset individuals in reference for clumping [required]"),
make_option("--ref_freq_chr", action="store", default=NA, type='character',
		help="Path to per chromosome reference PLINK .frq files [required]"),
make_option("--ref_maf", action="store", default=NA, type='numeric',
    help="Minor allele frequency threshold to be applied based on ref_freq_chr [optional]"),
make_option("--ref_pop_scale", action="store", default=NA, type='character',
		help="File containing the population code and location of the keep file [required]"),
make_option("--plink", action="store", default='plink', type='character',
		help="Path PLINK software binary [required]"),
make_option("--output", action="store", default='./Output', type='character',
		help="Path for output files [required]"),
make_option("--memory", action="store", default=5000, type='numeric',
		help="Memory limit [optional]"),
make_option("--n_cores", action="store", default=1, type='numeric',
		help="Number of cores for parallel computing [optional]"),
make_option("--sumstats", action="store", default=NA, type='character',
		help="GWAS summary statistics in LDSC format [required]"),
make_option("--gctb", action="store", default=NA, type='character',
    help="Path to GCTB binary [required]"),
make_option("--impute_N", action="store", default=T, type='logical',
    help="Logical indicating whether per variant N should imputed based on SE. [optional]"),
make_option("--P_max", action="store", default=NA, type='numeric',
    help="P-value threshold for filter variants [optional]"),
make_option("--robust", action="store", default=F, type='logical',
    help="Force robust GCTB parameterisation [optional]"),
make_option("--force_ref_frq", action="store", default=NA, type='character',
    help="Path to per chromosome freq-files containing allele frequencies to be forced"),
make_option("--test", action="store", default=NA, type='character',
    help="Specify number of SNPs to include [optional]"),
make_option("--ld_matrix_chr", action="store", default=NA, type='character',
		help="Path to per chromosome shrunk sparse LD matrix from GCTB [required]")
)

opt = parse_args(OptionParser(option_list=option_list))

library(data.table)
library(foreach)
library(doMC)
registerDoMC(opt$n_cores)

opt$output_dir<-paste0(dirname(opt$output),'/')
system(paste0('mkdir -p ',opt$output_dir))

CHROMS<-1:22

if(!is.na(opt$test)){
  if(grepl('chr', opt$test)){
    single_chr_test<-T
    CHROMS<-as.numeric(gsub('chr','',opt$test))
  } else {
    single_chr_test<-F
    opt$test<-as.numeric(opt$test)
  }
}

sink(file = paste(opt$output,'.log',sep=''), append = F)
cat(
'#################################################################
# polygenic_score_file_creator_SBLUP.R V1.0
# For questions contact Oliver Pain (oliver.pain@kcl.ac.uk)
#################################################################
Analysis started at',as.character(start.time),'
Options are:\n')

cat('Options are:\n')
print(opt)
cat('Analysis started at',as.character(start.time),'\n')
sink()

#####
# Read in sumstats and insert p-values
#####

sink(file = paste(opt$output,'.log',sep=''), append = T)
cat('Reading in GWAS and harmonising with reference.\n')
sink()

GWAS<-fread(cmd=paste0('zcat ',opt$sumstats))
GWAS<-GWAS[complete.cases(GWAS),]

# Extract subset if testing
if(!is.na(opt$test)){
  if(single_chr_test == F){
    sink(file = paste(opt$output,'.log',sep=''), append = T)
    cat('Testing mode enabled. Extracted ',opt$test,' variants per chromsome.\n', sep='')
    sink()
    
    GWAS_test<-NULL
    for(i in 1:22){
      GWAS_tmp<-GWAS[GWAS$CHR == i,]
      GWAS_tmp<-GWAS_tmp[order(GWAS_tmp$BP),]
      GWAS_tmp<-GWAS_tmp[1:opt$test,]
      GWAS_test<-rbind(GWAS_test,GWAS_tmp)
    }
    
    GWAS<-GWAS_test
    GWAS<-GWAS[complete.cases(GWAS),]
    rm(GWAS_test)
    print(table(GWAS$CHR))
    
  } else {
    sink(file = paste(opt$output,'.log',sep=''), append = T)
    cat('Testing mode enabled. Extracted chromosome ',opt$test,' variants per chromsome.\n', sep='')
    sink()
    
    GWAS<-GWAS[GWAS$CHR == CHROMS,]
    print(table(GWAS$CHR))
  }
}

sink(file = paste(opt$output,'.log',sep=''), append = T)
cat('GWAS contains',dim(GWAS)[1],'variants.\n')
sink()

###
# Change to COJO format
###

# If OR present, calculate BETA
if((sum(names(GWAS) == 'OR') == 1) & (sum(names(GWAS) == 'BETA') == 0)){
  GWAS$BETA<-log(GWAS$OR)
}

# Rename allele frequency column
if(sum(names(GWAS) == 'FREQ') == 1){
  GWAS$MAF<-GWAS$FREQ
} else {
  GWAS$MAF<-GWAS$REF.FREQ
}

if (!is.na(opt$force_ref_frq)){
  # override provided MAF with reference MAF
  sink(file = paste(opt$output,'.log',sep=''), append = T)
  cat('--force_ref_freq set, forcing reference allele frequencies\n')
  sink()
  
  freq_files <- list.files(dirname(opt$force_ref_frq), pattern=paste0(basename(opt$force_ref_frq),'.*.frq.*'), include.dirs = T, full.names = T)
  
  afreq <- do.call(rbind, lapply(freq_files, fread))
  
  # rename
  setnames(afreq, 'MAF', 'MAF_')
  setnames(afreq, 'A1', 'A1_')
  setnames(afreq, 'A2', 'A2_')
  
  GWAS <- data.table::merge.data.table(GWAS, afreq) # merge
      
  # force reference allele frequencies, keep original allele coding
  GWAS[, MAF := MAF_]
  GWAS[(A1 == A2_) & (A2 == A1_), MAF:=(1-MAF)]
  
}



GWAS<-GWAS[,c('SNP','A1','A2','MAF','BETA','SE','P','N'),with=F]
names(GWAS)<-c('SNP','A1','A2','freq','b','se','p','N')

# Check whether per variant sample size is available
if(length(unique(GWAS$N)) == 1){
  per_var_N<-F
  
  sink(file = paste(opt$output,'.log',sep=''), append = T)
  cat('Per variant N is not present\n')
  sink()
  
  if(opt$impute_N ==T){
    sink(file = paste(opt$output,'.log',sep=''), append = T)
    cat('Per variant N will be imputed.\n')
    sink()
  }
  
} else {
  per_var_N<-T
  
  sink(file = paste(opt$output,'.log',sep=''), append = T)
  cat('Per variant N is present\n')
  sink()
}

# Set maximum p-value threshold
if(!is.na(opt$P_max) == T){
  GWAS<-GWAS[GWAS$p <= opt$P_max,]
  
  sink(file = paste(opt$output,'.log',sep=''), append = T)
  cat('After p-value threshold of <= ',opt$P_max,', ', dim(GWAS)[1],' variants remain.\n', sep='')
  sink()
}

# Remove variants with SE of 0
if(sum(GWAS$se == 0) > 0){
  GWAS<-GWAS[GWAS$se!= 0,]
  
  sink(file = paste(opt$output,'.log',sep=''), append = T)
  cat('After removal of variants with SE of 0, ', dim(GWAS)[1],' variants remain.\n', sep='')
  sink()
}

# Write out cojo format sumstats
fwrite(GWAS, paste0(opt$output_dir,'GWAS_sumstats_COJO.txt'), sep=' ', na = "NA", quote=F)

if(!is.na(opt$test)){
  sink(file = paste(opt$output,'.log',sep=''), append = T)
  test_start.time <- Sys.time()
  cat('Test started at',as.character(test_start.time),'\n')
  sink()
}

#####
# Run GCTB SBayesR
#####

sink(file = paste(opt$output,'.log',sep=''), append = T)
cat('Running SBayesR analysis...')
sink()

is.odd <- function(x){x %% 2 != 0}
CHROMS_vector<-c(CHROMS, rep(NA,30)) 
CHROMS_mat<-matrix(CHROMS_vector,nrow=opt$n_cores, ncol=ceiling(22/opt$n_cores)) 
for(i in which(is.odd(1:dim(CHROMS_mat)[2]))){CHROMS_mat[,i]<-rev(CHROMS_mat[,i])} 
CHROMS_vector<-as.numeric(CHROMS_vector) 
CHROMS_vector<-CHROMS_vector[!is.na(CHROMS_vector)] 
print(CHROMS_vector)


# Note: it would be more efficient to parallelize this block together with the steps below...
if (opt$robust){
    # perform robust analysis if requested
    error<-foreach(i=CHROMS_vector, .combine=rbind) %dopar% {
        if(per_var_N == F & opt$impute_N == T){
            log<-system(paste0(opt$gctb,' --sbayes R --ldm ',opt$ld_matrix_chr,i,'.ldm.sparse --pi 0.95,0.02,0.02,0.01 --gamma 0.0,0.01,0.1,1 --gwas-summary ',opt$output_dir,'GWAS_sumstats_COJO.txt --chain-length 10000 --robust --exclude-mhc --burn-in 2000 --impute-n --out-freq 1000 --out ',opt$output_dir,'GWAS_sumstats_SBayesR.robust.chr',i), intern=T)
        } else {
          log<-system(paste0(opt$gctb,' --sbayes R --ldm ',opt$ld_matrix_chr,i,'.ldm.sparse --pi 0.95,0.02,0.02,0.01 --gamma 0.0,0.01,0.1,1 --gwas-summary ',opt$output_dir,'GWAS_sumstats_COJO.txt --chain-length 10000 --robust --exclude-mhc --burn-in 2000 --out-freq 1000 --out ',opt$output_dir,'GWAS_sumstats_SBayesR.robust.chr',i), intern=T)
        }
        writeLines(log, paste0(opt$output_dir,'SBayesR.robust.chr',i,'.log'))
        if(sum(grepl("MCMC cycles completed", log) == T) == 1 & sum(grepl("Analysis finished", log) == T) == 1){
            error_log<-data.frame(chr=i, Log='Analysis converged')
        }
        if(sum(grepl("MCMC cycles completed", log) == T) == 0 & sum(grepl("Analysis finished", log) == T) == 1){
            error_log<-data.frame(chr=i, Log='Analysis did not converge')
        }
        if(sum(grepl("MCMC cycles completed", log) == T) == 0 & sum(grepl("Analysis finished", log) == T) == 0){
            error_log<-data.frame(chr=i, Log='Error')
        }
        error_log
    } # dopar exit
    
    if(sum(grepl('Error', error$Log) == T) > 1){
        sink(file = paste(opt$output,'.log',sep=''), append = T)
        cat('An error occurred for',sum(grepl('Error', error$Log) == T),'chromosomes. Retry requesting more memory or run interactively to debug.\n')
        print(error)
        sink()
        system(paste0('rm ',opt$output_dir,'GWAS_sumstats_*'))
        stop('Error: SBayesR did not finish regularly.')
    }

}

# perform standard analysis with --rsq 0.95
error<-foreach(i=CHROMS_vector, .combine=rbind) %dopar% {
    if(per_var_N == F & opt$impute_N == T){
        log<-system(paste0(opt$gctb,' --sbayes R --ldm ',opt$ld_matrix_chr,i,'.ldm.sparse --pi 0.95,0.02,0.02,0.01 --gamma 0.0,0.01,0.1,1 --gwas-summary ',opt$output_dir,'GWAS_sumstats_COJO.txt --chain-length 10000 --rsq 0.95 --exclude-mhc --burn-in 2000 --impute-n --out-freq 1000 --out ',opt$output_dir,'GWAS_sumstats_SBayesR.chr',i), intern=T)
    } else {
        log<-system(paste0(opt$gctb,' --sbayes R --ldm ',opt$ld_matrix_chr,i,'.ldm.sparse --pi 0.95,0.02,0.02,0.01 --gamma 0.0,0.01,0.1,1 --gwas-summary ',opt$output_dir,'GWAS_sumstats_COJO.txt --chain-length 10000 --rsq 0.95 --exclude-mhc --burn-in 2000 --out-freq 1000 --out ',opt$output_dir,'GWAS_sumstats_SBayesR.chr',i), intern=T)
    }
    writeLines(log, paste0(opt$output_dir,'SBayesR.chr',i,'.log'))
    if(sum(grepl("MCMC cycles completed", log) == T) == 1 & sum(grepl("Analysis finished", log) == T) == 1){
        error_log<-data.frame(chr=i, Log='Analysis converged')
    }
    if(sum(grepl("MCMC cycles completed", log) == T) == 0 & sum(grepl("Analysis finished", log) == T) == 1){
        error_log<-data.frame(chr=i, Log='Analysis did not converge')
    }
    if(sum(grepl("MCMC cycles completed", log) == T) == 0 & sum(grepl("Analysis finished", log) == T) == 0){
        error_log<-data.frame(chr=i, Log='Error')
    }
    error_log
} # dopar exit

if(sum(grepl('Error', error$Log) == T) > 1){
    sink(file = paste(opt$output,'.log',sep=''), append = T)
    cat('An error occurred for',sum(grepl('Error', error$Log) == T),'chromosomes. Retry requesting more memory or run interactively to debug.\n')
    print(error)
    sink()
    # continue even if non-robust analysis failed.
    # system(paste0('rm ',opt$output_dir,'GWAS_sumstats_*'))
    # stop('Error: SBayesR did not finish regularly.')
}

sink(file = paste(opt$output,'.log',sep=''), append = T)
cat('Done!\n')
sink()


settings <- c('')
if (opt$robust){
    settings <- c(settings, 'robust') 
}

for (setting in settings){
    if (setting == ''){
        prefix <- 'GWAS_sumstats_SBayesR.chr'
    } else {
        prefix <- paste0('GWAS_sumstats_SBayesR.', setting, '.chr')
    }
    # Check whether analysis completed for all chromosomes
    comp_list<-list.files(path=opt$output_dir, pattern=paste0(prefix,'.*snpRes'))
    incomp<-c(CHROMS)[!(paste0(prefix,CHROMS,'.snpRes') %in% comp_list)]
    comp<-c(CHROMS)[(paste0(prefix,CHROMS,'.snpRes') %in% comp_list)]
                          
    # Combine per chromosome snpRes files
    snpRes<-NULL
    for(i in comp){
        snpRes<-rbind(snpRes, fread(paste0(opt$output_dir,prefix,i,'.snpRes')))
    }
    
    snpRes<-snpRes[,c('Chrom','Name','Position','A1','A2','A1Effect')]
    
    write.table(snpRes, paste0(opt$output_dir,gsub('\\.chr$','.GW.snpRes',prefix)), col.names=F, row.names=F, quote=F)
    
    # Combine per chromosome parRes files
    parRes_mcmc<-list()
    for(i in comp){
        parRes_mcmc[[i]]<-fread(paste0(opt$output_dir,prefix,i,'.mcmcsamples.Par'))
    }
    
    parRes<-NULL
    for(par in names(parRes_mcmc[[i]])){
        parRes_mcmc_par<-NULL
        for(i in comp){
            parRes_mcmc_par<-cbind(parRes_mcmc_par,parRes_mcmc[[i]][[par]])
        }
        
        parRes_mcmc_par_sum<-rowSums(parRes_mcmc_par)
        
        parRes_par<-data.frame(	Par=par,
                                Mean=mean(parRes_mcmc_par_sum),
                                SD=sd(parRes_mcmc_par_sum))
                                
        parRes<-rbind(parRes,parRes_par)
    }
                        
    sink(file = paste(opt$output,'.log',sep=''), append = T)
    cat('SNP-heritability estimate for setting "',setting,'" is ',parRes[parRes$Par == 'hsq', names(parRes) == 'Mean']," (SD=",parRes[parRes$Par == 'hsq', names(parRes) == 'SD'],").\n", sep='')
    sink()

    write.table(parRes, paste0(opt$output_dir,gsub('\\.chr$','.GW.parRes',prefix)), col.names=T, row.names=F, quote=F)
    
    system(paste0('rm ',opt$output_dir,prefix,'*'))     
    
    sink(file = paste(opt$output,'.log',sep=''), append = T)
    if(length(incomp) >=1){
        cat('No results for chromosomes',paste(incomp, collapse=','),'\n')
    }
    cat('Logs:\n')
    print(error)
    cat('\n')
    sink()
    
}
    

                      
if(!is.na(opt$test)){
    end.time <- Sys.time()
    time.taken <- end.time - test_start.time
    sink(file = paste(opt$output,'.log',sep=''), append = T)
    cat('Test run finished at',as.character(end.time),'\n')
    cat('Test duration was',as.character(round(time.taken,2)),attr(time.taken, 'units'),'\n')
    system(paste0('rm ',opt$output_dir,'*Res')) 
    sink()
    q()
}
  
system(paste0('rm ',opt$output_dir,'GWAS_sumstats_COJO.txt'))

####
# Calculate mean and sd of polygenic scores at each threshold
####

# Calculate polygenic scores for reference individuals
sink(file = paste(opt$output,'.log',sep=''), append = T)
cat('Calculating polygenic scores in reference...')
sink()

scales <- foreach(setting=settings, .combine=rbind) %dopar% {
    
    if (setting == ''){
        prefix <- 'GWAS_sumstats_SBayesR'
        profile_prefix <- paste0(opt$output_dir,'ref.profiles')
        profile <- paste0(opt$output_dir,'ref.profiles.profile')
    } else {
        prefix <- paste0('GWAS_sumstats_SBayesR.', setting)
        profile_prefix <- paste0(opt$output_dir,'ref.profiles.', setting)
        profile <- paste0(opt$output_dir,'ref.profiles.',setting,'.profile')
    }
    
    system(paste0(opt$plink, ' --bfile ',opt$ref_plink,' --score ',opt$output_dir,prefix,'.GW.snpRes 2 4 6 sum --out ',profile_prefix,' --memory ',floor(opt$memory*0.7)))

    # Read in the reference scores
    scores<-fread(profile)
    
    # Calculate the mean and sd of scores for each population specified in pop_scale
    pop_keep_files<-read.table(opt$ref_pop_scale, header=F, stringsAsFactors=F)
    
    # this is an ugly hack...
    if (setting == ''){
        name_out <- 'SCORE_default'
    } else {
        name_out <- paste0('SCORE_',setting)
    }
    
    wrap_mean_sd <- function(k){
        pop<-pop_keep_files$V1[k]
        keep<-fread(pop_keep_files$V2[k], header=F)
        scores_keep<-scores[(scores$FID %in% keep$V1),]
        ref_scale<-data.frame('Pop'=pop,'Param'=name_out,'Mean'=round(mean(scores_keep$SCORESUM),3), 'SD'=round(sd(scores_keep$SCORESUM),3))
        return(ref_scale)
    }
        
    ref_scores <- do.call(rbind, lapply(1:dim(pop_keep_files)[1], wrap_mean_sd))
    ref_scores
}

for (pop in unique(scales$Pop)){
    fwrite(scales[scales$Pop == pop,2:ncol(scales)], paste0(opt$output,'.',pop,'.scale'), sep=' ')
}


sink(file = paste(opt$output,'.log',sep=''), append = T)
cat('Done!\n')
sink()

###
# Clean up temporary files
###

system(paste0('rm ',opt$output_dir,'ref.profiles.*'))

end.time <- Sys.time()
time.taken <- end.time - start.time
sink(file = paste(opt$output,'.log',sep=''), append = T)
cat('Analysis finished at',as.character(end.time),'\n')
cat('Analysis duration was',as.character(round(time.taken,2)),attr(time.taken, 'units'),'\n')
sink()