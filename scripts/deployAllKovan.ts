import  deployAll  from './initDeploy'

deployAll('Matic')
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
