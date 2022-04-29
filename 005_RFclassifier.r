# This script trains a model on HQ cells using lineage specific genes identified via FindAllMarkers 
# The model is then used to predict lineage annotations on LQ dataset
# parallelization require base R to run efficiently. Radian or Jupyter are not optimal and may flood memory

# packages
library(Seurat)
library(qs)
library(singleCellNet)
library(data.table)
library(stringr)
library(parallel)

setwd('/Users/ibishara/Desktop/FELINE_C1/')
numCores <- detectCores()
numCores 

# data
lineage.markers <- read.table('Annotation.lineage.markers.txt', sep = '\t' )
celltype.markers <- read.table('Annotation.celltype.markers.txt', sep = '\t' )

# High quality FELINE C1 data
seu_HQ <- qread(file = "seu_HQ.qs", nthreads = numCores)
seu_HQ <- subset(x = seu_HQ, subset = Celltype != "Normal epithelial cells")   ## Removes normal epithelial cells. Genes unique to normal epi cells are removed from analysis downstream
meta <- seu_HQ@meta.data
seu.HQ.counts <- GetAssayData(seu_HQ, assay = "RNA")

setwd('/Users/ibishara/Desktop/FELINE_C1/downsample/')
path.list <- list.files(path = getwd(), pattern = ".*down_.*\\.txt", recursive = TRUE) # create a list of downsampled count tables
path.list <- path.list[ !grepl("reads_downsample/round/|reads_downsample/nofloor/", path.list) ] #temp
# path.list <- path.list[1:2]

# Notes:
# var1 <- counts/genes table path
# var2 <- classified variable e.g. Lineage, Cell type. Has to be a column name in metadata entered as a character ""
# ncells <- number of cells sampled from each condition to train/validate the model
# nGenes <- ??? 

# log10 transformation
# # reads <- log10(reads)
# is.na(log)<-sapply(log, is.infinite)
# log[is.na(log)]<-0

foo <- function(var1, var2, ncells, nGenes, out){

# var1 <- "genes_downsample/binary/genes_down_3.0.txt"
# var2 <- 'Lineage'
# ncells <- 400
# nGenes <- 25
# out <- 'summ'

        if(substr(var1, 18, 20) == 'bin'){ output.dir <- 'model_performance_genes_binary_without_normal_pdf/'  
                method <- 'binary'
        } else if(substr(var1, 18, 20) == 'non'){ output.dir <- 'model_performance_genes_nonbinary_without_normal_pdf/'  
                method <- 'non-binary'
        } else if(substr(var1, 18, 20) == 'flo'){ output.dir <- 'model_performance_reads_floor_without_normal_pdf/'  
                method <- 'floor'
        } else if(substr(var1, 18, 20) == 'nof'){ output.dir <- 'model_performance_reads_nofloor_without_normal_pdf/' 
                method <- 'no-floor' 
        } else if(substr(var1, 18, 20) == 'rou'){ output.dir <- 'model_performance_reads_round_without_normal_pdf/' 
                method <- 'no-floor' }
        
        dir.create(output.dir )
        condition <- str_sub(var1, -18, -5) # capture the condition of counts e.g., genes/reads and subsample threshold
        print(noquote(paste('processing', var1)))
        # Counts/genes downsampled from HQ FELINE C1 data
        counts <- as.data.frame(fread( var1, sep='\t')) # load downsamples counts / genes 
        # find gene symbol columns, set as rownames, delete column and any previous columns
        for(i in 1:10){   if (!is.numeric(counts[,i]) ) {
                rownames(counts) <- counts[,i]
                counts <- counts[-(1:i)]
        }}

        if(var2 == 'Lineage') { markers <- lineage.markers 
        } else if( var2 == 'Celltype') { markers <- celltype.markers }

        common.genes <- intersect(intersect(rownames(seu.HQ.counts), markers$gene), rownames(counts))
        seu.HQ.counts <- seu.HQ.counts[common.genes, ]
        # counts <- counts[common.genes, ] ## issue: This step reduces the number of genes hence yield worse performance/bias 
  
        #prevent overlap between training and validation cells 
        meta.sub <- meta[colnames(counts) ,] # Since count table is a subset of all cells (transformed cells), this is added to only sample cells from transformed matrix

        set.seed(100) 
        #Sample for validation from transformed data
        stTestList = splitCommon(sampTab = meta.sub, ncells = 100, dLevel = var2)  # not enough 400 cells/class to sample high read cut-off
        stTest = stTestList[[1]]
        expTest = counts[ ,rownames(stTest)]

        #Sample for training from untransformed data
        meta.train <- meta[!rownames(meta) %in% rownames(stTestList[[1]]) ,]  # all other non used cells available for training 

        stList = splitCommon(sampTab = meta.train, ncells = ncells, dLevel = var2) # At certain thresholds, there's not enough remaining cells for training 
        stTrain = stList[[1]]
        expTrain = seu.HQ.counts[, rownames(stTrain)]

        # model training on lineage
        system.time(class_info <- scn_train(stTrain = stTrain, expTrain = expTrain, 
                                nTopGenes = nGenes, nRand = 50, nTrees = 1000, nTopGenePairs = nGenes*2, 
                                dLevel = var2, colName_samp = "Cell"))


        classRes_val_all = scn_predict(cnProc=class_info[['cnProc']], expDat=expTest, nrand = 50)  # number of training and validation cells must be equal. genes in model must be in validation set. | issue: some dropped genes lead to error
        tm_heldoutassessment = assess_comm(ct_scores = classRes_val_all, stTrain = stTrain, stQuery = stTest, 
                                        dLevelSID = "Cell", classTrain = var2, classQuery = var2, nRand = 50)

        table_type <- str_sub(condition, -15, -10)
        if(table_type == 'genes' & max(counts) > 1){ counts[counts > 0] <- 1 } # convert non-binary gene tables to binary to count num genes
        total <- as.numeric(colSums(counts))
        AUC <- tm_heldoutassessment$AUPRC_w
        threshold <- str_sub(condition, -3, -1)
        avg.reads <- mean(total)
        method <- substr(output.dir, 25, 29)
        # summary out
        summ <- c(var2, table_type, threshold, method, AUC, ncells, nGenes, avg.reads) ### Turning both to lists can export list of list of list

        # total ditribution 
        dist <- c(total)
        
        if (out == 'dist'){out <- dist
        } else {out <- summ}

        ## total in binary represents number of genes. total in non-binary represents counts. add if statement to get number of genes. 
        print(noquote('Generating plots'))
        # plots 
        pdf(paste(output.dir, condition, '_', var2, '.pdf', sep = ''))
                hist(total, main = paste(condition, 'by', var2, sep = ' '))
                plot(plot_PRs(tm_heldoutassessment))
                plot(plot_attr(classRes = classRes_val_all, sampTab=stTest, nrand=50, dLevel=var2, sid="Cell"))
                plot(plot_metrics(tm_heldoutassessment))
        dev.off()
        return(out)  # returns summary and total 
}


# Summary
summ.lineage <- mclapply(path.list, FUN = foo, var2 = 'Lineage', ncells = 400, nGenes = 25, out = 'summ', mc.cores= numCores) # out = 'summ' (Default) 
summ.lineage <- do.call(rbind, summ.lineage)

summ.celltype <- mclapply(path.list, FUN = foo, var2 = 'Celltype', ncells = 400, nGenes = 25, out = 'summ', mc.cores= numCores)
summ.celltype <- do.call(rbind, summ.celltype)

comb.summ <- rbind(summ.lineage, summ.celltype )
colnames(comb.summ) <- c( 'class.var', 'source', 'threshold','method', 'AUC',  'nCells', 'nGenes', 'avg.UMI/genes')
write.table(comb.summ, 'performance_summary_400_400cells.txt', col.names = TRUE, sep = '\t') 


# Reads/genes distribution
condition <- str_sub(substr(path.list, 18, nchar(path.list)), -30, -5) # capture the condition of counts e.g., genes/reads and subsample threshold

dist.lineage <- mclapply(path.list, FUN = foo, var2 = 'Lineage', ncells = 400, nGenes = 25, out = 'dist', mc.cores= numCores)
dist.lineage <- do.call(cbind, dist.lineage )
colnames(dist.lineage) <- condition
write.table(dist.lineage, 'lineage_distributions_by_condition.txt', col.names = TRUE, sep = '\t') 

dist.celltype <- mclapply(path.list, FUN = foo, var2 = 'Celltype', ncells = 400, nGenes = 25, out = 'dist', mc.cores= numCores)
dist.celltype <- do.call(cbind, dist.celltype)
colnames(dist.celltype) <- condition
write.table(dist.celltype, 'celltype_distributions_by_condition.txt', col.names = TRUE, sep = '\t') 





#########################################################

## Mitochondrial content