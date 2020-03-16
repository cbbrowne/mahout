VERSION := $(shell cat version)
PVERSION := mahout-$(VERSION)
VDIR := $(ARTIFACT_TARGET)/$(PVERSION)
TARBALL := $(ARTIFACT_TARGET)/$(PVERSION).tar.bz2

ifndef ARTIFACT_TARGET
$(error ARTIFACT_TARGET is not set - this is the directory in which to deploy output artifacts)
endif

all: $(TARBALL)

$(TARBALL): README.html README.org mahout
	mkdir -p $(VDIR)
	cp README.html README.org mahout $(VDIR)
	(cd $(ARTIFACT_TARGET) ; tar cfvj $(TARBALL) $(PVERSION) )

README.html: org-to-html README.org
	ruby org-to-html

clean:
	rm -rf $(VDIR)
	rm -f $(TARBALL)
