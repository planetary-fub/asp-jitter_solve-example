#!/bin/bash

#Download images from PDS
wget https://pds-imaging.jpl.nasa.gov/data/mro/mars_reconnaissance_orbiter/ctx/mrox_1201/data/G02_018948_1749_XN_05S270W.IMG
wget https://pds-imaging.jpl.nasa.gov/data/mro/mars_reconnaissance_orbiter/ctx/mrox_1610/data/G22_026873_1771_XN_02S270W.IMG

img1=G02_018948_1749_XN_05S270W
img2=G22_026873_1771_XN_02S270W

dirprefix=G02G22

#automatic ISIS3 pre-processing
#cam2map4stereo.py ${img1}.cal.eo.cub ${img2}.cal.eo.cub 

#manual ISIS3 pre-processing
for i in $img1 $img2 ; do
  mroctx2isis from=${i}.IMG to=${i}.cub
  spiceinit from=${i}.cub
  month=`echo $i|cut -c 1-3`
  # Flatfiles downloaded from http://dx.doi.org/10.17169/refubium-37236
  ctxcal from=${i}.cub to=${i}.cal.cub flatfile=${month}.flat.cub
  ctxevenodd from=${i}.cal.cub to=${i}.cal.eo.cub
  cam2map from=${i}.cal.eo.cub to=${i}.cal.eo.map.cub pixres=MPP resolution=5 defaultrange=MAP minlat=-6.66 maxlat=-0.87 minlon=89.58 maxlon=90.45
  python gen_csm.py ${i}.cub
done

### Reference Datasets ###
gdal_translate -co compress=lzw -co TILED=yes -co INTERLEAVE=BAND -co BLOCKXSIZE=256 -co BLOCKYSIZE=256 \
-projwin -18820 -51680 18810 -394590 -projwin_srs '+proj=sinu +lon_0=89.899073984935 +x_0=0 +y_0=0 +a=3396190 +b=3396190 +units=m +no_defs' \
$ISISDATA/base/dems/molaMarsPlanetaryRadius0005.cub ref_dem_shift.tif
image_calc -c "var_0-190" -d float32 ref_dem_shift.tif -o ref_dem.tif
geodiff --absolute --csv-format 1:lon,2:lat,5:radius_m mola.csv ref_dem.tif

### Uncorrected DTM creation ###
rm -rfv ${dirprefix}-ba
bundle_adjust \
--ip-per-image 20000 \
--max-pairwise-matches 10000 \
--tri-weight 0.05 \
--camera-weight 0 \
--remove-outliers-params '75.0 3.0 20 20' \
${img1}.cal.eo.cub \
${img2}.cal.eo.cub \
${img1}.json \
${img2}.json \
-o ${dirprefix}-ba/run

rm -rfv ${dirprefix}-stereo
parallel_stereo \
--processes 1 \
--threads-multiprocess 4 \
--threads-singleprocess 4 \
--bundle-adjust-prefix ${dirprefix}-ba/run \
--stereo-algorithm asp_mgm \
--num-matches-from-disp-triplets 40000 \
--alignment-method local_epipolar \
${img1}.cal.eo.cub \
${img2}.cal.eo.cub \
${img1}.json \
${img2}.json \
${dirprefix}-stereo/run

### Create Hillshade from uncorrected DTM ###
point2dem --errorimage ${dirprefix}-stereo/run-PC.tif
hillshade -e 25 -a 300 ${dirprefix}-stereo/run-DEM.tif
colormap ${dirprefix}-stereo/run-DEM.tif -s ${dirprefix}-stereo/run-DEM_HILLSHADE.tif -o ${dirprefix}-stereo/run-DEM_COLOR_HILLSHADE.tif
colormap --min 0 --max 10 ${dirprefix}-stereo/run-IntersectionErr.tif

### Align DTM to MOLA and re-create 
#The value in --max-displacement may need tuning (Section 14.48).
pc_align --max-displacement 400 --csv-format 1:lon,2:lat,5:radius_m ${dirprefix}-stereo/run-DEM.tif mola.csv --save-inv-transformed-reference-points -o ${dirprefix}-stereo/run-align
point2dem ${dirprefix}-stereo/run-align-trans_reference.tif
#has to be done for all unprojected DEMs if you want to e.g. measure profiles
point2dem --t_srs "+proj=eqc +lat_ts=0 +lat_0=0 +lon_0=180 +x_0=0 +y_0=0 +R=3396190" ${dirprefix}-stereo/run-align-trans_reference.tif -o ${dirprefix}-stereo/run-proj-align-trans_reference

### Apply transform to cameras
rm -rf ${dirprefix}-ba_align
bundle_adjust \
--input-adjustments-prefix ${dirprefix}-ba/run \
--initial-transform ${dirprefix}-stereo/run-align-inverse-transform.txt \
--apply-initial-transform-only=yes \
${img1}.cal.eo.cub \
${img2}.cal.eo.cub \
${img1}.json \
${img2}.json \
-o ${dirprefix}-ba_align/run

# commented out some parameters, feel free to experiment and copy back in
##--max-initial-reprojection-error 20
##--clean-match-files-prefix run_ba/run \
##--num-lines-per-position 1000 \
##--num-lines-per-orientation 1000 \
jitter_solve \
--input-adjustments-prefix ${dirprefix}-ba_align/run \
--max-pairwise-matches 100000 \
--match-files-prefix ${dirprefix}-stereo/run-disp \
--max-initial-reprojection-error 20 \
--heights-from-dem ref_dem.tif \
--heights-from-dem-weight 0.05 \
--heights-from-dem-robust-threshold 0.05 \
--num-iterations 1000 \
--anchor-weight 0 \
--tri-weight 0 \
${img1}.cal.eo.cub \
${img2}.cal.eo.cub \
${img1}.json \
${img2}.json \
-o ${dirprefix}-jitter/run

### Redo Jitter with optimzed cameras
# These parameters have been commented out
#--corr-kernel 5 5 \
#--subpixel-mode 12 \
#--cost-mode 4 \
parallel_stereo \
--prev-run-prefix ${dirprefix}-stereo/run \
--stereo-algorithm asp_mgm \
--processes 1 \
--threads-multiprocess 4 \
--threads-singleprocess 4 \
--alignment-method local_epipolar \
${img1}.cal.eo.cub \
${img2}.cal.eo.cub \
${dirprefix}-jitter/run-${img1}.adjusted_state.json \
${dirprefix}-jitter/run-${img2}.adjusted_state.json \
${dirprefix}-stereo_jitter/run

point2dem --errorimage ${dirprefix}-stereo_jitter/run-PC.tif
hillshade -e 25 -a 300 ${dirprefix}-stereo_jitter/run-DEM.tif
colormap ${dirprefix}-stereo_jitter/run-DEM.tif -s ${dirprefix}-stereo_jitter/run-DEM_HILLSHADE.tif -o ${dirprefix}-stereo_jitter/run-DEM_COLOR_HILLSHADE.tif
point2dem --t_srs "+proj=eqc +lat_ts=0 +lat_0=0 +lon_0=180 +x_0=0 +y_0=0 +R=3396190" --errorimage ${dirprefix}-stereo_jitter/run-PC.tif -o ${dirprefix}-stereo_jitter/run-proj

#to plot the ray intersection error before and after solving for jitter
colormap --min 0 --max 10 ${dirprefix}-stereo/run-IntersectionErr.tif
colormap --min 0 --max 10 ${dirprefix}-stereo_jitter/run-IntersectionErr.tif

#to compute absolute difference between: 
#1) the sparse MOLA dataset and the DEM after alignment and before solving for jitter - G02G22-stereo/run-diff.csv
#2) the sparse MOLA dataset and the DEM produced after solving jitter - G02G22-stereo_jitter_posdef_oridef_defaults-trionly/run-diff.csv
geodiff --absolute --csv-format 1:lon,2:lat,5:radius_m ${dirprefix}-stereo/run-proj-align-trans_reference-DEM.tif mola.csv -o ${dirprefix}-stereo/run
geodiff --absolute --csv-format 1:lon,2:lat,5:radius_m ${dirprefix}-stereo_jitter/run-DEM.tif mola.csv -o ${dirprefix}-stereo_jitter/run

#to compute absolute difference between: 
#1) the reference DEM and the DEM after alignment and before solving for jitter - G02G22-stereo/run-diff.tif
#2) the reference DEM and the DEM produced after solving jitter
geodiff --absolute ref_dem.tif ${dirprefix}-stereo/run-proj-align-trans_reference-DEM.tif -o ${dirprefix}-stereo/run
colormap --min 0 --max 20 ${dirprefix}-stereo/run-diff.tif
geodiff --absolute ref_dem.tif ${dirprefix}-stereo_jitter/run-proj-DEM.tif -o ${dirprefix}-stereo_jitter/run
colormap --min 0 --max 20 ${dirprefix}-stereo_jitter/run-diff.tif

exit 0
