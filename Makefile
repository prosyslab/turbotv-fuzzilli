ISSUE ?= 1126249
D8S_PATH ?= /home/user/turbo-tv-exp/d8s-instrumented

distmaps/$(ISSUE).txt: $(D8S_PATH)/$(ISSUE)/cfg
	mkdir -p distmaps
	./cfg_preprocess.py $(D8S_PATH)/$(ISSUE)/cfg /home/user/turbo-tv-exp/targets/$(ISSUE).txt > distmaps/$(ISSUE).txt

COV_PATH=. DISTMAP_FILE=1234764_dist swift run FuzzilliCli --profile=v8 --timeout=500  --storagePath=/data/fuzzilli/1011-test --staticCorpus --corpusImportMode=full --importCorpus=./seeds-temp ././d8s-instrumented/1234764/d8  --overwrite


FUZZILLI_OPTS = --staticCorpus --corpusImportMode=full --overwrite \
				--importCorpus=./seeds-fuzzilli-1126249 \
				--profile=v8 \
				--timeout=500 \
				--storagePath=./storage/$(ISSUE) \
				--logLevel=verbose

.PHONY: test-$(ISSUE)
test-$(ISSUE): distmaps/$(ISSUE).txt
	swift build
	COV_PATH=. DISTMAP_FILE=distmaps/$(ISSUE).txt swift run FuzzilliCli $(D8S_PATH)/$(ISSUE)/d8 $(FUZZILLI_OPTS)