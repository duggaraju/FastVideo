using './main.bicep'

param prefix = 'video'
param systemVmSize = 'Standard_D2ds_v5'
param spotVmSize = 'Standard_D8ds_v5'
param spotMinCount = 0
param spotMaxCount = 10
param regularVmSize = 'Standard_D8ds_v5'
param regularMinCount = 0
param regularMaxCount = 10
